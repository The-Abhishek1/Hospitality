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
insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values(:'rid',:'tenant',:'pid',:'guest','confirmed',current_date,current_date+2,5000,'INR');
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
-- Inbox images are staff replies, independent of guest-menu configuration.
update public.conversations set last_inbound_at=now()where id=:'cid';
\set photo 11200000-0000-4000-8000-000000000001
\set request 11200000-0000-4000-8000-000000000002
insert into public.inbox_photo_uploads(id,property_id,conversation_id,request_id,uploaded_by,storage_path,digest,delivery_url,expires_at)
values(:'photo',:'pid',:'cid',:'request',:'owner',:'pid'||'/'||:'cid'||'/'||:'request'||'.jpg',repeat('a',64),'https://storage.test/photo.jpg',now()+interval '7 days');
set local role authenticated;
select public.inbox_send_photo(:'pid',:'cid',:'request',:'photo','Hotel pool photo') as photo_mid\gset
select is(public.inbox_send_photo(:'pid',:'cid',:'request',:'photo','Hotel pool photo'),:'photo_mid'::uuid,'duplicate photo submission returns the same message');
select throws_ok(format('select public.inbox_send_photo(%L,%L,%L,%L,''Changed caption'')',:'pid',:'cid',:'request',:'photo'),'22023',null,'an idempotency key cannot silently change a queued caption');
select throws_ok(format('select public.inbox_send_photo(%L,%L,%L,%L,''bad'')','e3000000-0000-0000-0000-000000000002',:'cid',:'request',:'photo'),'42501',null,'photo cannot cross hotel boundaries');
select throws_ok(format('insert into public.inbox_photo_uploads(id,property_id)values(%L,%L)',gen_random_uuid(),:'pid'),'42501',null,'clients cannot forge uploaded photos');
reset role;
select is(private.inbox_delivery_error(:'photo_mid'),null,'photo delivery works with no published guest menu');
select is((select outbound_payload#>>'{image,caption}'from public.messages where id=:'photo_mid'),'Hotel pool photo','caption is delivered as photo content');
update public.messages set next_attempt_at=now()+interval '1 day'where id<>:'photo_mid'and status='queued';
set local role service_role;
select is((select outbound_payload#>>'{image,caption}'from public.claim_outbound_messages_v5(1,false,false)where message_id=:'photo_mid'),'Hotel pool photo','the real worker claim returns photo and caption payload');
select is((select count(*)::int from public.claim_outbound_messages_v5(1,false,false)),0,'worker cannot claim an in-flight photo twice');
reset role;

update public.conversations set last_inbound_at=now()-interval '25 hours'where id=:'cid';
select alike(private.inbox_delivery_error(:'photo_mid'),'%window closed%','photo queued before window closure is blocked at delivery');
update public.messages set status='failed'where id=:'photo_mid';
set local role authenticated;
select throws_ok(format('select public.inbox_retry(%L)',:'photo_mid'),'22023',null,'expired window cannot be bypassed by Retry photo');
select throws_ok(format('select public.inbox_photo_context(%L,%L,%L)',:'pid',:'cid',gen_random_uuid()),'22023',null,'closed window blocks new uploads');
reset role;
update public.conversations set last_inbound_at=now()where id=:'cid';
update public.inbox_photo_uploads set expires_at=now()-interval '1 minute'where id=:'photo';
select alike(private.inbox_delivery_error(:'photo_mid'),'%expired%','expired photo delivery links cannot be retried');
update public.inbox_photo_uploads set expires_at=now()+interval '7 days'where id=:'photo';
insert into public.consent_records(tenant_id,property_id,wa_contact_id,status,source,recorded_at)values(:'tenant',:'pid','919111111111','opted_out','keyword',clock_timestamp());
select alike(private.inbox_delivery_error(:'photo_mid'),'%opted out%','STOP blocks photo delivery before provider dispatch');
insert into public.consent_records(tenant_id,property_id,wa_contact_id,status,source,recorded_at)values(:'tenant',:'pid','919111111111','opted_in','keyword',clock_timestamp());

update public.messages set guest_identity_reset_at=now()where id=:'photo_mid';
select alike(private.inbox_delivery_error(:'photo_mid'),'%reset%','reset guest identities block previously queued images');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"e1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select is((select count(*)::int from public.inbox_photo_uploads where id=:'photo'),0,'another hotel owner cannot read attachment metadata');
reset role;
update public.reservations set status='cancelled'where id in(:'paused_rid',:'return_rid');
-- Every distinct greeting is answered; provider replays and worker ticks remain idempotent.
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select public.save_whatsapp_journey(:'pid',0,true,1,false,'photo');
reset role;set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','simple-hi-1','919111111111','Asha','simple-hi-1','text','Hi','{}',now());
select is(public.dispatch_whatsapp_guest_replies(50,'https://guest.test'),1,'first Hi gets a reply');
select public.ingest_whatsapp_inbound('12345678001','simple-hi-2','919111111111','Asha','simple-hi-2','text','Hello','{}',now());
select is(public.dispatch_whatsapp_guest_replies(50,'https://guest.test'),1,'a distinct Hello within 30 seconds also gets a reply');
select public.ingest_whatsapp_inbound('12345678001','simple-hi-2','919111111111','Asha','simple-hi-2','text','Hello','{}',now());
select is(public.dispatch_whatsapp_guest_replies(50,'https://guest.test'),0,'replayed provider ID does not get another reply');
select is(public.dispatch_whatsapp_guest_replies(50,'https://guest.test'),0,'worker replay does not resend a menu');
select *from finish();rollback;
