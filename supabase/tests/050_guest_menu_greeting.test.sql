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
select lives_ok(format('select public.save_whatsapp_journey(%L,0,true,2,true)',:'pid'),'owner enables the WhatsApp-first journey');
select throws_ok(format('select public.save_whatsapp_journey(%L,0,true,2,true)',:'pid'),'40001',null,'configuration is version checked');
select throws_ok($$select public.save_whatsapp_journey('e3000000-0000-0000-0000-000000000002',0,true,1,true)$$,'42501',null,'cannot configure another hotel');
select public.save_whatsapp_automation_rule(:'pid','booking_confirmed',0,true,:'tid','["guest_name","hotel_name","portal_url"]',0);
select public.save_whatsapp_automation_rule(:'pid','documents_approved',0,true,:'tid','["guest_name","hotel_name","portal_url"]',0);
reset role;
insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values(:'rid',:'tenant',:'pid',:'guest','confirmed',current_date,current_date+2,5000,'INR');
select is((select count(*)::integer from public.whatsapp_automation_events where property_id=:'pid'and event_key='booking_confirmed'),1,'new booking automatically captures a welcome');
set local role service_role;
select is(public.dispatch_whatsapp_automations(50,'https://guest.test'),0,'no prior contact permission holds the first welcome');
reset role;
select ok((select reason like '%permission%'from public.whatsapp_automation_events where reservation_id=:'rid'and event_key='booking_confirmed'),'delivery hold explains missing permission');
set local role authenticated;
select public.record_whatsapp_booking_contact(:'pid',:'rid','Guest requested a booking welcome and verified their WhatsApp number at booking.',true);
reset role;
select is((select count(*)::integer from public.whatsapp_guest_authorizations where property_id=:'pid'),0,'booking contact permission never forges ongoing opt-in');
select is((select count(*)::integer from public.whatsapp_marketing_permissions where property_id=:'pid'),0,'booking never grants marketing permission');
set local role service_role;
select is(public.dispatch_whatsapp_automations(50,'https://guest.test'),1,'first welcome queues automatically without ongoing consent');
select is(public.dispatch_whatsapp_automations(50,'https://guest.test'),0,'initial welcome is not repeated');
reset role;
select ok((select body like '%https://guest.test/s/%?view=documents%'from public.messages where automation_event_id is not null and property_id=:'pid'),'welcome opens the exact secure document task');
select is((select template_components#>>'{0,parameters,0,image,link}'from public.messages where automation_event_id is not null and property_id=:'pid'),'https://hotel.test/front.jpg','approved welcome sends its configured hotel image');
select id as cid from public.conversations where property_id=:'pid' \gset
select is(private.inbox_delivery_error((select id from public.messages where property_id=:'pid'and automation_event_id is not null)),null,'initial welcome passes delivery revalidation outside service window');
update public.whatsapp_template_assets set image_url='https://hotel.test/replaced.jpg'where property_id=:'pid';
select is(private.inbox_delivery_error((select id from public.messages where automation_event_id is not null and property_id=:'pid')),'Template delivery image changed.','changed image invalidates the queued photo snapshot');
update public.whatsapp_template_assets set image_url='https://hotel.test/front.jpg'where property_id=:'pid';
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','journey-hi','919111111111','Asha','journey-hi','text','Hi','{}',now());
select is(public.dispatch_whatsapp_guest_replies(50,'https://guest.test'),1,'Hi receives preferences even when no menu was saved');
reset role;
select is((select count(*)::integer from private.whatsapp_journey_actions where conversation_id=:'cid'and action='updates'),1,'stay consent is an actual in-chat button');
select 'journey:'||id as choice from private.whatsapp_journey_actions where conversation_id=:'cid'and action='updates' \gset
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','journey-agree','919111111111','Asha','journey-agree','interactive','Enable stay updates',jsonb_build_object('interactive',jsonb_build_object('button_reply',jsonb_build_object('id',:'choice','title','Enable stay updates'))),now());
select is(public.dispatch_whatsapp_guest_replies(50,'https://guest.test'),1,'consent selection continues the arrival journey');
select is(public.dispatch_whatsapp_guest_replies(50,'https://guest.test'),0,'replayed worker tick repeats no action');
reset role;
select is((select count(*)::integer from public.whatsapp_guest_authorizations where property_id=:'pid'and status='granted'),1,'real inbound button records stay permission');
select is((select source from public.whatsapp_guest_authorizations where property_id=:'pid'),'guest_whatsapp','consent source is the actual guest');
select ok((select source_message_id is not null from public.whatsapp_guest_authorizations where property_id=:'pid'),'consent preserves inbound evidence');
select is((select count(*)::integer from public.whatsapp_marketing_permissions where property_id=:'pid'),0,'stay choice leaves offers off');

select set_config('t.menu',jsonb_build_object('intro','CUSTOM GREETING QA: choose how we can help.','items',jsonb_build_array(jsonb_build_object('action','stay','label','My stay','enabled',true)),'categories',jsonb_build_array(jsonb_build_object('id','a0000000-0000-4000-8000-000000000001','label','Hotel information','enabled',true,'services',jsonb_build_array(jsonb_build_object('id','a0000000-0000-4000-9000-000000000001','label','Hotel help','enabled',true,'action','reply','template_id',:'tid')))))::text,true);
set local role authenticated;
select public.save_whatsapp_guest_menu(:'pid',0,false,current_setting('t.menu')::jsonb);
reset role;
update public.messages set created_at=now()-interval '1 minute'where property_id=:'pid'and direction='out';
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','greeting-draft-hi','919111111111','Asha','greeting-draft-hi','text','Hi','{}',now());
select is(public.dispatch_whatsapp_guest_replies(50,'https://guest.test'),1,'Hi still receives the built-in journey while custom menu is a draft');
reset role;
select is((select count(*)::integer from public.messages where property_id=:'pid'and direction='out'and body=current_setting('t.menu')::jsonb->>'intro'),0,'draft greeting never leaks into live replies');
select ok((select exists(select 1 from public.messages where property_id=:'pid'and direction='out'and journey_purpose='menu'and body like 'Welcome, Asha.%')),'built-in greeting remains the fallback');
set local role authenticated;
select public.save_whatsapp_guest_menu(:'pid',1,true,current_setting('t.menu')::jsonb);
reset role;
update public.messages set created_at=now()-interval '1 minute'where property_id=:'pid'and direction='out';
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','greeting-published-hi','919111111111','Asha','greeting-published-hi','text','Hello','{}',now());
select is(public.dispatch_whatsapp_guest_replies(50,'https://guest.test'),1,'Hello queues the published custom menu through the guest journey');
reset role;
select is((select m.outbound_payload#>>'{interactive,body,text}'from public.messages m join public.messages source on source.id=m.guest_reply_to where source.wa_message_id='greeting-published-hi'and m.direction='out'),current_setting('t.menu')::jsonb->>'intro','saved greeting is the actual WhatsApp interactive menu body');
select is((select m.outbound_payload#>>'{interactive,action,sections,0,rows,0,title}'from public.messages m join public.messages source on source.id=m.guest_reply_to where source.wa_message_id='greeting-published-hi'and m.direction='out'),'Hotel information','greeting is attached to real category choices');
select is((select count(*)::integer from public.messages m join public.messages source on source.id=m.guest_reply_to where source.wa_message_id='greeting-published-hi'and m.direction='out'),1,'one greeting/menu reply, not an unrelated standalone message');
select is(public.dispatch_whatsapp_guest_replies(50,'https://guest.test'),0,'replayed worker tick does not repeat the greeting');
select *from finish();rollback;
