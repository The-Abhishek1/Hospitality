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
insert into public.whatsapp_journey_settings(property_id,enabled)values(:'pid',true);
insert into public.conversations(id,tenant_id,property_id,connection_id,wa_contact_id,contact_name,guest_id,last_inbound_at)values('e7000000-0000-0000-0000-000000000001',:'tenant',:'pid','e6000000-0000-0000-0000-000000000001','919111111111','Asha',:'guest',now());
\set cid e7000000-0000-0000-0000-000000000001
insert into public.whatsapp_guest_authorizations(property_id,tenant_id,guest_id,wa_contact_id,conversation_id,status,evidence)values(:'pid',:'tenant',:'guest','919111111111',:'cid','granted','Synthetic verified guest agreement.');
insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values
(:'rid',:'tenant',:'pid',:'guest','confirmed',current_date,current_date+1,5000,'INR'),
('e5000000-0000-0000-0000-000000000002',:'tenant',:'pid',:'guest','confirmed',current_date-1,current_date,5000,'INR'),
('e5000000-0000-0000-0000-000000000003',:'tenant',:'pid',:'guest','confirmed',current_date+10,current_date+12,5000,'INR');
select is(private.journey_stay(:'cid'),:'rid'::uuid,'Current confirmed stay wins over a prior checkout date and future booking');
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','fix-hi','919111111111','Asha','fix-hi','text','Hi','{}',now())as inbound \gset
reset role;
select id as inbound from public.messages where property_id=:'pid'and wa_message_id='fix-hi' \gset
select is(private.handle_whatsapp_journey(:'cid',:'inbound','hi','https://hotel.test'),1,'Hi routes to the current guest journey');
select is((select human_handoff from public.conversations where id=:'cid'),false,'Current-stay matching does not automatically pause the chat');
-- A real ambiguity uses a verified booking picker rather than guessing or silently pausing.
insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values('e5000000-0000-0000-0000-000000000004',:'tenant',:'pid',:'guest','confirmed',current_date,current_date+2,5000,'INR');
select is(private.journey_stay(:'cid'),null::uuid,'Two current stays require an explicit choice');
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','fix-choose','919111111111','Asha','fix-choose','text','Hi','{}',now())as choose_message \gset
reset role;
select id as choose_message from public.messages where property_id=:'pid'and wa_message_id='fix-choose' \gset
select is(private.handle_whatsapp_journey(:'cid',:'choose_message','hi','https://hotel.test'),1,'Ambiguous verified guest receives booking choices');
select is((select human_handoff from public.conversations where id=:'cid'),false,'A booking choice does not pause automation');
select is((select count(*)::int from private.whatsapp_journey_actions where conversation_id=:'cid'and action='choose_stay'),2,'Picker contains only the two current bookings');
select is(private.inbox_delivery_error((select id from public.messages where guest_reply_to=:'choose_message'and journey_purpose='verify_stay')),null::text,'Private picker passes source and identity delivery checks');
select id as choice_id from private.whatsapp_journey_actions where conversation_id=:'cid'and action='choose_stay'and reservation_id=:'rid' \gset
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','fix-selected','919111111111','Asha','fix-selected','interactive','Choose booking','{}',now())as choice_message \gset
reset role;
select id as choice_message from public.messages where property_id=:'pid'and wa_message_id='fix-selected' \gset
select is(private.handle_whatsapp_journey(:'cid',:'choice_message','journey:'||:'choice_id','https://hotel.test'),1,'Scoped choice continues to the normal menu');
select is(private.journey_stay(:'cid'),:'rid'::uuid,'Selected current booking is remembered for the expiring action session');
select is(private.handle_whatsapp_journey(:'cid',:'choice_message','journey:'||:'choice_id','https://hotel.test'),0,'Consumed booking choices cannot be replayed');
update public.conversations set guest_id=null where id=:'cid';
select ok(private.inbox_delivery_error((select id from public.messages where guest_reply_to=:'choose_message'and journey_purpose='verify_stay'))is not null,'A changed guest binding suppresses an already queued private picker');
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','fix-unknown','919222222222','Unknown','fix-unknown','text','Hi','{}',now())as unknown_message \gset
reset role;
select id as unknown_message from public.messages where property_id=:'pid'and wa_message_id='fix-unknown' \gset
select id as unknown_chat from public.conversations where property_id=:'pid'and wa_contact_id='919222222222' \gset
select is(private.handle_whatsapp_journey(:'unknown_chat',:'unknown_message','hi','https://hotel.test'),1,'Unknown sender receives verification guidance');
select is((select human_handoff from public.conversations where id=:'unknown_chat'),false,'Unknown Hi never silently requests human handling');
select ok(not exists(select 1 from public.messages where conversation_id=:'unknown_chat'and direction='out'and body like '%Asha%'),'Unknown sender receives no private guest identity');
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','fix-human','919222222222','Unknown','fix-human','text','reception','{}',now())as reception_message \gset
reset role;
select id as reception_message from public.messages where property_id=:'pid'and wa_message_id='fix-human' \gset
select is(private.handle_whatsapp_journey(:'unknown_chat',:'reception_message','reception','https://hotel.test'),1,'Explicit reception request remains available');
select is((select human_handoff from public.conversations where id=:'unknown_chat'),true,'Explicit reception request still pauses automatic replies');
update public.conversations set guest_id=:'guest'where id=:'cid';
update public.reservations set status='no_show'where id in(:'rid','e5000000-0000-0000-0000-000000000004');
select is(private.journey_stay(:'cid'),'e5000000-0000-0000-0000-000000000003'::uuid,'Next eligible future booking is reachable after current stays close');
-- Restore a single current stay for the document notification regression.
update public.reservations set status='confirmed'where id=:'rid';
set local role service_role;
select public.sync_whatsapp_provider_templates('e6000000-0000-0000-0000-000000000001','12345678002','[{"provider_id":"902","name":"document_received_test","language":"en_US","category":"utility","provider_status":"APPROVED","body":"We received your identity photo. The hotel will review it.","parameter_names":[],"supported":true,"service_supported":true,"definition":{"components":[{"type":"BODY","text":"We received your identity photo. The hotel will review it."}]}}]');
reset role;
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select public.save_whatsapp_automation_rule(:'pid','documents_received',0,true,(select id from public.message_templates where property_id=:'pid'and name='document_received_test'),'[]',0);
reset role;
insert into public.guest_documents(id,tenant_id,property_id,reservation_id,guest_id,doc_type,storage_path,mime_type,size_bytes,status,review_method)values('ed000000-0000-0000-0000-000000000003',:'tenant',:'pid',:'rid',:'guest','id_proof','local-133-photo','image/jpeg',10,'pending_upload','photo');
update public.guest_documents set status='uploaded'where id='ed000000-0000-0000-0000-000000000003';
update public.guest_documents set status='image_ready'where id='ed000000-0000-0000-0000-000000000003';
select id as receipt from public.whatsapp_automation_events where property_id=:'pid'and event_key='documents_received' \gset
select is(private.whatsapp_automation_error(:'receipt'),null::text,'Rebuilt photo still qualifies for its document-received notification');
set local role service_role;
select is(public.dispatch_whatsapp_automations(50,'https://hotel.test'),1,'Upload receipt queues after photo processing instead of being skipped');
reset role;
update public.whatsapp_guest_authorizations set status='revoked'where property_id=:'pid';
select ok(private.whatsapp_automation_error(:'receipt')is not null,'Photo receipt still requires guest stay-update permission');
update public.whatsapp_guest_authorizations set status='granted'where property_id=:'pid';
update public.guest_documents set status='image_invalid'where id='ed000000-0000-0000-0000-000000000003';
select is(private.whatsapp_automation_error(:'receipt'),'Source status changed.','Invalid image cannot send a received-for-review receipt');
select ok(not has_function_privilege('authenticated','private.journey_candidate_stays(uuid)','execute'),'Staff browser cannot query private matching candidates directly');
select *from finish();
rollback;
