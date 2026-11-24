begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select no_plan();
insert into auth.users(id,email)values('e1000000-0000-0000-0000-000000000001','automation-owner@test.invalid'),('e1000000-0000-0000-0000-000000000002','automation-other@test.invalid');
insert into public.tenants(id,name,slug)values('e2000000-0000-0000-0000-000000000001','Automation A','automation-a'),('e2000000-0000-0000-0000-000000000002','Automation B','automation-b');
insert into public.properties(id,tenant_id,name,property_type)values('e3000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','Hotel A','hotel'),('e3000000-0000-0000-0000-000000000002','e2000000-0000-0000-0000-000000000002','Hotel B','hotel');
insert into public.tenant_memberships(tenant_id,user_id,role)values('e2000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001','owner'),('e2000000-0000-0000-0000-000000000002','e1000000-0000-0000-0000-000000000002','owner');
insert into public.guests(id,tenant_id,full_name,phone)values('e4000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','Asha','+919111111111');
insert into public.whatsapp_connections(id,tenant_id,property_id,phone_number_id,waba_id,display_phone,credentials_ref)values('e6000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','12345678001','12345678002','+919999999999','automation-test');
\set pid e3000000-0000-0000-0000-000000000001
\set tenant e2000000-0000-0000-0000-000000000001
\set guest e4000000-0000-0000-0000-000000000001
\set rid e5000000-0000-0000-0000-000000000001
\set owner e1000000-0000-0000-0000-000000000001
set local role service_role;
select public.sync_whatsapp_provider_templates('e6000000-0000-0000-0000-000000000001','12345678002','[{"provider_id":"901","name":"journey_welcome","language":"en_US","category":"utility","provider_status":"APPROVED","body":"Hello {{guest_name}}, welcome to {{hotel_name}}. Upload securely: {{portal_url}}. Reply Hi to choose updates.","parameter_names":["guest_name","hotel_name","portal_url"],"supported":true,"service_supported":true,"definition":{"components":[{"type":"BODY"},{"type":"HEADER","format":"IMAGE"},{"type":"BUTTONS","buttons":[{"type":"URL","url":"https://hotel.test/location","text":"Location"}]}]}}]');
reset role;
insert into public.whatsapp_template_assets values(:'pid','901','https://hotel.test/front.jpg');
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select id as tid from public.message_templates where property_id=:'pid'and name='journey_welcome' \gset
reset role;set local role service_role;
select public.sync_whatsapp_provider_templates('e6000000-0000-0000-0000-000000000001','12345678002','[
 {"provider_id":"902","name":"hotel_photo_reply","language":"en_US","category":"utility","provider_status":"APPROVED","body":"Here is the hotel photo you requested. Contact reception for more details.","parameter_names":[],"supported":true,"service_supported":true,"definition":{"components":[{"type":"HEADER","format":"IMAGE"},{"type":"BODY","text":"Here is the hotel photo you requested. Contact reception for more details."}]}},
 {"provider_id":"903","name":"hotel_text_reply","language":"en_US","category":"utility","provider_status":"APPROVED","body":"Here is the hotel information you requested. Contact reception for more details.","parameter_names":[],"supported":true,"service_supported":true,"definition":{"components":[{"type":"BODY","text":"Here is the hotel information you requested. Contact reception for more details."}]}}
]');
select public.ingest_whatsapp_inbound('12345678001','photo-template-in','919111111111','Asha','photo-template-in','text','Hi','{}')as cid\gset
reset role;
insert into public.whatsapp_template_assets values(:'pid','902','https://hotel.test/pool.jpg');
update public.conversations set last_inbound_at=now()-interval '25 hours'where id=:'cid';
set local role authenticated;
select id as photo_tid from public.message_templates where property_id=:'pid'and name='hotel_photo_reply'\gset
select gen_random_uuid()as request\gset
select public.inbox_send(:'cid',:'request',null,:'photo_tid')as mid\gset
select is(public.inbox_send(:'cid',:'request',null,:'photo_tid'),:'mid'::uuid,'approved photo template retries return the original message');
select is((select template_components#>>'{0,parameters,0,image,link}'from public.messages where id=:'mid'),'https://hotel.test/pool.jpg','manual template includes the provider image header component');
select ok((select (v->>'supported')::boolean from jsonb_array_elements(public.inbox_workspace(:'pid',jsonb_build_object('c',:'cid'))->'templates')v where v->>'id'=:'photo_tid'),'Inbox offers approved photo templates outside the service window');
select is((select v->>'image_url'from jsonb_array_elements(public.inbox_workspace(:'pid',jsonb_build_object('c',:'cid'))->'templates')v where v->>'id'=:'photo_tid'),'https://hotel.test/pool.jpg','composer receives the photo preview');
select is((select v#>>'{outbound_payload,template,components,0,parameters,0,image,link}'from jsonb_array_elements(public.inbox_workspace(:'pid',jsonb_build_object('c',:'cid'))->'messages')v where v->>'id'=:'mid'),'https://hotel.test/pool.jpg','chat history receives the sent template photo preview');
reset role;
select is(private.inbox_delivery_error(:'mid'),null,'approved photo template can be delivered after the 24-hour window');
update public.whatsapp_template_assets set image_url='https://hotel.test/replacement.jpg'where property_id=:'pid'and provider_template_id='902';
select alike(private.inbox_delivery_error(:'mid'),'%photo changed%','replacing an image blocks an already queued template snapshot');
update public.whatsapp_template_assets set image_url='https://hotel.test/pool.jpg'where property_id=:'pid'and provider_template_id='902';
update public.message_templates set provider_checked_at=now()-interval '25 hours'where id=:'photo_tid';
set local role authenticated;
select throws_ok(format('select public.inbox_send(%L,%L,null,%L)',:'cid',gen_random_uuid(),:'photo_tid'),'22023',null,'stale approval cannot be used for a new photo template message');
select ok(not(select (v->>'supported')::boolean from jsonb_array_elements(public.inbox_workspace(:'pid')->'templates')v where v->>'id'=:'photo_tid'),'stale templates are not offered as ready replies');
reset role;
select alike(private.inbox_delivery_error(:'mid'),'%synchronized%','approval is checked again at delivery');
update public.message_templates set provider_checked_at=now()where id=:'photo_tid';
delete from public.whatsapp_template_assets where property_id=:'pid'and provider_template_id='902';
set local role authenticated;
select throws_ok(format('select public.inbox_send(%L,%L,null,%L)',:'cid',gen_random_uuid(),:'photo_tid'),'22023',null,'missing image is rejected before queuing a provider request');
select ok(not(select (v->>'supported')::boolean from jsonb_array_elements(public.inbox_workspace(:'pid')->'templates')v where v->>'id'=:'photo_tid'),'missing-image templates are excluded from ready replies');
select throws_ok(format('select public.inbox_send(%L,%L,''Free photo caption'',null)',:'cid',gen_random_uuid()),'22023',null,'photo templates do not reopen free-text replies outside the window');
select lives_ok(format('select public.inbox_send(%L,%L,null,(select id from public.message_templates where property_id=%L and name=''hotel_text_reply''))',:'cid',gen_random_uuid(),:'pid'),'ordinary approved text template delivery still works');
select *from finish();rollback;
