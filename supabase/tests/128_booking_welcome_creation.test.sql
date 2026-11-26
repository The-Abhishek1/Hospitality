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
select lives_ok(format('select public.save_whatsapp_automation_rule(%L,''booking_confirmed'',0,true,%L,''["guest_name","hotel_name","portal_url"]'',0)',:'pid',:'tid'),'welcome activates independently of document admission settings');
select is((public.booking_welcome_status(:'pid')->>'state'),'ready','welcome is ready while the guest journey is off');
reset role;
select ok(not exists(select 1 from public.whatsapp_journey_settings where property_id=:'pid'and enabled),'welcome never enables document admission or self check-in');
insert into public.accommodation_types(id,tenant_id,property_id,name,max_occupancy,base_rate)values('e1123000-0000-0000-0000-000000000001',:'tenant',:'pid','Welcome room',2,2500);
insert into public.accommodation_units(tenant_id,property_id,type_id,name)select :'tenant',:'pid','e1123000-0000-0000-0000-000000000001','W'||n from generate_series(1,3)n;
set local role authenticated;
select public.frontdesk_create_whatsapp(:'pid','INR','e1126000-0000-0000-0000-000000000001','Asha','+919111111111','','e1123000-0000-0000-0000-000000000001',current_date,current_date+2,1,0,null,null,'','direct',5000,false,'')as rid \gset
select guest_id as guest from public.reservations where id=:'rid' \gset
reset role;
set local role service_role;
select is(public.dispatch_whatsapp_automations(50,'https://guest.test'),0,'welcome still waits for prior contact permission');
reset role;set local role authenticated;
select public.record_whatsapp_booking_contact(:'pid',:'rid','Guest requested a welcome on this verified number during booking.',true);
reset role;set local role service_role;
select is(public.dispatch_whatsapp_automations(50,'https://guest.test'),1,'standalone welcome queues with prior booking permission');
select is(public.dispatch_whatsapp_automations(50,'https://guest.test'),0,'worker replay cannot send a second welcome');
reset role;
select is((select count(*)::int from public.whatsapp_guest_authorizations where property_id=:'pid'),0,'welcome does not grant ongoing consent');
select id as cid from public.conversations where property_id=:'pid'\gset
select id as mid from public.messages where property_id=:'pid'and automation_event_id is not null\gset
select is(private.inbox_delivery_error(:'mid'),null,'photo welcome passes all delivery guards without journey enabled');
select ok((select body like '%https://guest.test/s/%?view=documents%'from public.messages where id=:'mid'),'welcome has a private document-task link');
set local role authenticated;
select throws_ok(format('select public.save_whatsapp_automation_rule(%L,''booking_confirmed'',1,true,%L,''["guest_name","hotel_name","guest_name"]'',0)',:'pid',:'tid'),'22023',null,'welcome activation requires its personal guest link');
select throws_ok(format('select public.save_whatsapp_automation_rule(%L,''booking_confirmed'',1,true,%L,''["guest_name","hotel_name","portal_url"]'',10)',:'pid',:'tid'),'22023',null,'welcome cannot acquire a hidden sending delay');
select public.save_whatsapp_automation_rule(:'pid','booking_confirmed',1,false,:'tid','["guest_name","hotel_name","portal_url"]',0);
reset role;
insert into public.reservations(tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values(:'tenant',:'pid',:'guest','confirmed',current_date+3,current_date+4,5000,'INR')returning id as paused_rid\gset
select is((select count(*)::int from public.whatsapp_automation_events where reservation_id=:'paused_rid'),0,'Off does not queue a booking welcome');
set local role authenticated;
select public.save_whatsapp_automation_rule(:'pid','booking_confirmed',2,true,:'tid','["guest_name","hotel_name","portal_url"]',0);
reset role;
select is((select count(*)::int from public.whatsapp_automation_events where reservation_id=:'paused_rid'),0,'turning On does not backfill past bookings');
insert into public.reservations(tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values(:'tenant',:'pid',:'guest','confirmed',current_date+5,current_date+6,5000,'INR')returning id as return_rid\gset
set local role authenticated;
select public.record_whatsapp_booking_contact(:'pid',:'return_rid','Returning guest requested the welcome for a separate new booking.',true);
reset role;set local role service_role;
select is(public.dispatch_whatsapp_automations(50,'https://guest.test'),1,'returning guest gets one welcome for their new booking');
reset role;

set local role authenticated;
select public.frontdesk_create_whatsapp(:'pid','INR','e1126000-0000-0000-0000-000000000002','New booking guest','+919111111112','','e1123000-0000-0000-0000-000000000001',current_date+10,current_date+12,1,0,null,null,'','direct',5000,true,'Guest agreed to the booking welcome during reservation.')as new_rid \gset
select is((public.booking_welcome_status(:'pid',:'new_rid')->>'permission_recorded')::boolean,true,'New booking form records prior permission with its reservation');
select is(public.frontdesk_create_whatsapp(:'pid','INR','e1126000-0000-0000-0000-000000000002','New booking guest','+919111111112','','e1123000-0000-0000-0000-000000000001',current_date+10,current_date+12,1,0,null,null,'','direct',5000,true,'Guest agreed to the booking welcome during reservation.'),:'new_rid'::uuid,'Retrying booking confirmation does not create another reservation');
reset role;set local role service_role;
select is(public.dispatch_whatsapp_automations(50,'https://guest.test'),1,'Real booking confirmation queues its welcome automatically');
select is(public.dispatch_whatsapp_automations(50,'https://guest.test'),0,'Replay never queues another welcome for the same booking');
reset role;
select is((select count(*)::integer from public.messages m join public.whatsapp_automation_events e on e.message_id=m.id where e.reservation_id=:'new_rid'),1,'Exactly one first WhatsApp message is stored');
select is((select private.inbox_delivery_error(m.id)from public.messages m join public.whatsapp_automation_events e on e.message_id=m.id where e.reservation_id=:'new_rid'),null,'New booking message passes the worker delivery guard');
select ok((select m.body like '%https://guest.test/s/%?view=documents%'from public.messages m join public.whatsapp_automation_events e on e.message_id=m.id where e.reservation_id=:'new_rid'),'Welcome contains the private document helper link');
select *from finish();rollback;
