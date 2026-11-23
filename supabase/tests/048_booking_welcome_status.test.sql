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

select public.save_whatsapp_journey(:'pid',0,true,1,true,'photo');
reset role;
insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values(:'rid',:'tenant',:'pid',:'guest','confirmed',current_date,current_date+2,5000,'INR');
set local role authenticated;
select is(public.booking_welcome_status(:'pid',:'rid')->>'state','off','booking explains inactive welcome rule');
select throws_ok(format('select public.request_booking_welcome(%L,%L)',:'pid',:'rid'),'22023',null,'off rule cannot send a welcome');
select public.record_whatsapp_booking_contact(:'pid',:'rid','Guest requested a booking welcome and verified their WhatsApp number at booking.',true);
select public.save_whatsapp_automation_rule(:'pid','booking_confirmed',0,true,:'tid','["guest_name","hotel_name","portal_url"]',0);
reset role;
select is((select count(*)::integer from public.whatsapp_automation_events where reservation_id=:'rid'),0,'enabling rule never silently backfills previous guests');
set local role authenticated;
select is(public.booking_welcome_status(:'pid',:'rid')->>'state','not_queued','missing event shown after configuration');
select is(public.booking_welcome_status(:'pid',:'rid')->>'can_send','true','recent booking with permission allows one welcome');
select lives_ok(format('select public.request_booking_welcome(%L,%L)',:'pid',:'rid'),'request captures missed welcome');
select lives_ok(format('select public.request_booking_welcome(%L,%L)',:'pid',:'rid'),'retrying request is duplicate safe');
reset role;
select is((select count(*)::integer from public.whatsapp_automation_events where reservation_id=:'rid'and event_key='booking_confirmed'),1,'one event per booking even after repeated request');
select is((select count(*)::integer from public.whatsapp_guest_authorizations where property_id=:'pid'),0,'initial contact permission never opts into later updates');
set local role service_role;
select is(public.dispatch_whatsapp_automations(50,'https://hotel.test'),1,'existing worker queues welcome with personal document link');
reset role;
select is((select count(*)::integer from public.messages where automation_event_id in(select id from public.whatsapp_automation_events where reservation_id=:'rid')),1,'one outbound welcome');
select ok((select body like '%?view=documents&via=whatsapp%'from public.messages where automation_event_id in(select id from public.whatsapp_automation_events where reservation_id=:'rid')),'welcome includes focused private document task');
set local role authenticated;
select is(public.booking_welcome_status(:'pid',:'rid')->>'state','queued','reservation shows actual queued delivery');
select is(public.request_booking_welcome(:'pid',:'rid')->>'state','queued','queued welcome cannot be requested again');
reset role;
update public.messages set status='sent'where automation_event_id in(select id from public.whatsapp_automation_events where reservation_id=:'rid');
set local role authenticated;
select is(public.request_booking_welcome(:'pid',:'rid')->>'state','sent','sent welcome is never resent');
select throws_ok(format('select public.booking_welcome_status(%L,%L)','e3000000-0000-0000-0000-000000000002',:'rid'),'42501',null,'another hotel status protected');
select set_config('request.jwt.claims','{"sub":"e1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok(format('select public.request_booking_welcome(%L,%L)',:'pid',:'rid'),'42501',null,'other hotel owner cannot send');
set local role anon;
select ok(not has_function_privilege('anon','public.request_booking_welcome(uuid,uuid)','execute'),'anonymous visitor cannot trigger welcomes');
reset role;
select is((select count(*)::integer from public.messages where automation_event_id in(select id from public.whatsapp_automation_events where reservation_id=:'rid')),1,'retries never add a duplicate sent message');
select *from finish();rollback;
