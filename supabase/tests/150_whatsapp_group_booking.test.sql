begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select no_plan();
insert into auth.users(id,email)values('f1000000-0000-0000-0000-000000000001','enquiry-owner@test.invalid'),('f1000000-0000-0000-0000-000000000002','enquiry-other@test.invalid');
insert into public.tenants(id,name,slug)values('f2000000-0000-0000-0000-000000000001','Enquiry A','group-enquiry-a'),('f2000000-0000-0000-0000-000000000002','Enquiry B','group-enquiry-b');
insert into public.properties(id,tenant_id,name,property_type)values('f3000000-0000-0000-0000-000000000001','f2000000-0000-0000-0000-000000000001','Enquiry Resort','resort'),('f3000000-0000-0000-0000-000000000002','f2000000-0000-0000-0000-000000000002','Other Hotel','hotel');
insert into public.tenant_memberships(tenant_id,user_id,role)values('f2000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001','owner'),('f2000000-0000-0000-0000-000000000002','f1000000-0000-0000-0000-000000000002','owner');
insert into public.whatsapp_connections(id,tenant_id,property_id,phone_number_id,waba_id,credentials_ref)values('f6000000-0000-0000-0000-000000000001','f2000000-0000-0000-0000-000000000001','f3000000-0000-0000-0000-000000000001','135001','135002','test-enquiries');
insert into public.accommodation_types(id,tenant_id,property_id,name,base_rate,max_occupancy)values('f7000000-0000-0000-0000-000000000001','f2000000-0000-0000-0000-000000000001','f3000000-0000-0000-0000-000000000001','Deluxe',2500,3);
insert into public.accommodation_units(id,tenant_id,property_id,type_id,name)values('f8000000-0000-0000-0000-000000000001','f2000000-0000-0000-0000-000000000001','f3000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000001','D101');
\set pid f3000000-0000-0000-0000-000000000001
\set owner f1000000-0000-0000-0000-000000000001
update public.properties set payment_test_mode=true where id=:'pid';
insert into public.hotel_payment_connections(id,tenant_id,property_id,mode,key_hint,checkout_enabled)values('a1410000-0000-0000-0000-000000000001','f2000000-0000-0000-0000-000000000001',:'pid','test','rzp_test_fixture',true);
insert into private.hotel_payment_credentials values('a1410000-0000-0000-0000-000000000001','v1.fixture');
insert into private.payment_worker_configuration(id,origin,secret_id,enabled)values(true,'https://invalid.example',gen_random_uuid(),true)on conflict(id)do update set enabled=true;
select ((now()at time zone 'Asia/Kolkata')::date+1)::text as arrival,((now()at time zone 'Asia/Kolkata')::date+3)::text as departure \gset
insert into public.room_date_prices(tenant_id,property_id,type_id,night,amount)values('f2000000-0000-0000-0000-000000000001',:'pid','f7000000-0000-0000-0000-000000000001',:'arrival',5500);
set local role service_role;
select public.sync_whatsapp_provider_templates('f6000000-0000-0000-0000-000000000001','135002','[{"provider_id":"1350001","name":"enquiry_booking_welcome","language":"en_US","category":"utility","provider_status":"APPROVED","body":"Hello {{guest_name}}, welcome to {{hotel_name}}. Upload documents at {{portal_url}}. Reply Hi for help.","parameter_names":["guest_name","hotel_name","portal_url"],"supported":true,"service_supported":true,"definition":{"components":[{"type":"BODY"}]}}]');
reset role;
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select public.save_whatsapp_journey(:'pid',0,true,1,true,'photo');
select id as tid from public.message_templates where property_id=:'pid'and name='enquiry_booking_welcome' \gset
select public.save_whatsapp_automation_rule(:'pid','booking_confirmed',0,true,:'tid','["guest_name","hotel_name","portal_url"]',0);
select is((public.whatsapp_booking_workspace(:'pid')->>'enabled')::boolean,true,'WhatsApp booking defaults on alongside the guest journey');
select throws_ok($$select public.save_whatsapp_booking_settings('f3000000-0000-0000-0000-000000000002',0,false)$$,'42501',null,'hotel owners cannot change another hotel’s booking settings');
reset role;
create function pg_temp.incoming(p_phone text,p_body text)returns uuid language plpgsql as $$declare cid uuid;key text:=gen_random_uuid()::text;begin
 cid:=public.ingest_whatsapp_inbound('135001',key,p_phone,'New Customer',key,case when p_body like 'journey:%'then'interactive'else'text'end,p_body,case when p_body like 'journey:%'then jsonb_build_object('interactive',jsonb_build_object('button_reply',jsonb_build_object('id',p_body,'title','Choose')))else'{}'::jsonb end,now());
 perform public.dispatch_whatsapp_guest_replies(50,'https://hotel.test');return cid;
end $$;
create function pg_temp.pick(p_cid uuid,p_action text)returns text language sql as $$select 'journey:'||id from private.whatsapp_journey_actions where conversation_id=p_cid and action=p_action and consumed_at is null order by created_at desc,id desc limit 1$$;

update public.property_settings set check_in_time='13:00',check_out_time='11:30'where property_id=:'pid';
insert into public.accommodation_types(id,tenant_id,property_id,name,base_rate,max_occupancy)values('f7000000-0000-0000-0000-000000000002','f2000000-0000-0000-0000-000000000001',:'pid','Family',4500.01,5);
insert into public.accommodation_units(tenant_id,property_id,type_id,name)select 'f2000000-0000-0000-0000-000000000001',:'pid','f7000000-0000-0000-0000-000000000001','D'||n from generate_series(102,104)n;
insert into public.accommodation_units(tenant_id,property_id,type_id,name)select 'f2000000-0000-0000-0000-000000000001',:'pid','f7000000-0000-0000-0000-000000000002','F'||n from generate_series(201,203)n;
create function pg_temp.pick_room(p_cid uuid,p_type uuid)returns text language sql as $$select 'journey:'||a.id from private.whatsapp_journey_actions a join private.whatsapp_booking_sessions s on s.conversation_id=a.conversation_id where a.conversation_id=p_cid and a.action='enquiry_room'and a.details->>'type'=p_type::text and a.details->>'revision'=s.version::text and a.consumed_at is null order by a.created_at desc limit 1$$;
create function pg_temp.group_quote(p_phone text,p_offset integer)returns uuid language plpgsql as $$declare c uuid;d date:=(now()at time zone'Asia/Kolkata')::date+p_offset;begin
 c:=pg_temp.incoming(p_phone,'BOOK');perform pg_temp.incoming(p_phone,to_char(d,'DD-MM-YYYY')||' to '||to_char(d+2,'DD-MM-YYYY'));perform pg_temp.incoming(p_phone,'11 members');perform pg_temp.incoming(p_phone,'3 rooms');perform pg_temp.incoming(p_phone,'Group Contact');
 perform pg_temp.incoming(p_phone,pg_temp.pick_room(c,'f7000000-0000-0000-0000-000000000001'));perform pg_temp.incoming(p_phone,'2');
 perform pg_temp.incoming(p_phone,pg_temp.pick_room(c,'f7000000-0000-0000-0000-000000000002'));perform pg_temp.incoming(p_phone,'1');return c;
end $$;
create function pg_temp.snapshot(p_request uuid,p_tag text,p_status text default'paid',p_refunds jsonb default'[]')returns jsonb language sql as $$select jsonb_build_object('link',jsonb_build_object('id','plink_'||p_tag,'reference_id',replace(j.id::text,'-',''),'amount',j.amount,'currency','INR','status',p_status,'order_id','order_'||p_tag,'short_url','https://rzp.io/'||p_tag,'notes',jsonb_build_object('property_id',j.property_id,'reservation_id',j.reservation_id)),'payment',jsonb_build_object('id','pay_'||p_tag,'status','captured','captured',true,'amount',j.amount,'currency','INR','order_id','order_'||p_tag,'method','upi'),'refunds',p_refunds)from public.hotel_payment_requests j where j.id=p_request$$;
select is(private.enquiry_dates('31-02-2027 to 03-03-2027'),null::date[],'invalid calendar dates are rejected');
select is(private.enquiry_dates('one date 01-12-2026'),null::date[],'both dates are required');
select is(private.whatsapp_public_hotel_intent('3 rooms'),null::text,'room count is not intercepted as a public hotel question');
select pg_temp.group_quote('919000001501',1)as cid \gset
select is((select step from private.whatsapp_booking_sessions where conversation_id=:'cid'),'confirm','mixed room type group reaches one review');
select is((select room_count from private.whatsapp_booking_sessions where conversation_id=:'cid'),3,'guest selects multiple rooms without reception');
select is((select sum((x->>'members')::integer)::integer from private.whatsapp_booking_sessions s,jsonb_array_elements(s.room_items)x where s.conversation_id=:'cid'),11,'all members are distributed within room capacities');
select is((select quote from private.whatsapp_booking_sessions where conversation_id=:'cid'),25000.02::numeric,'mixed room quote includes date override and per-room nights');
select ok(exists(select 1 from public.messages where conversation_id=:'cid'and body like'Review your booking%'and body like'%from 13:00%'and body like'%by 11:30%'),'review includes both hotel times');
select ok(not exists(select 1 from public.messages where conversation_id=:'cid'and body like'Let’s book%'and(body like'%Enquiry Resort%'or body like'%one room%')),'opening booking question has no hotel name or single-room restriction');
select pg_temp.incoming('919000001501',pg_temp.pick(:'cid','enquiry_confirm'));
select reservation_id as rid,payment_request_id as intent,group_id as grp from private.whatsapp_booking_sessions where conversation_id=:'cid' \gset
select is((select count(*)::integer from public.reservations where group_id=:'grp'),3,'one group appears as three ordinary room reservations');
select is((select count(*)::integer from public.unit_holds h join public.reservations r on r.id=h.reservation_id where r.group_id=:'grp'and h.active),3,'all rooms held atomically');
select is((select count(*)::integer from public.hotel_payment_requests where booking_group_id=:'grp'),1,'group has one deposit link');
select is((select amount from public.hotel_payment_requests where id=:'intent'),1250001::bigint,'one exact 50 percent deposit for the group');
select is((select sum(amount)::bigint from public.hotel_payment_allocations where request_id=:'intent'),1250001::bigint,'room allocations sum to captured paise exactly');
select ok(not exists(select 1 from public.reservations where group_id=:'grp'and status<>'pending_payment'),'no room confirmed before payment');
select is((select count(*)::integer from public.whatsapp_automation_events where property_id=:'pid'and event_key='booking_confirmed'),0,'no welcome before deposit');
select folio_id as secondary_folio,reservation_id as secondary_rid from public.hotel_payment_allocations where request_id=:'intent'and position=2 \gset
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select is((public.payment_workspace(:'pid',:'secondary_rid')->'requests'->0->>'id'),:'intent','secondary room billing shows shared group payment');
select throws_ok(format('select public.collect_folio_payment(%L,10,''cash'',null)',:'secondary_folio'),'22023',null,'manual collection cannot double collect a secondary group room');
reset role;
update public.hotel_payment_requests set lease=gen_random_uuid(),state='creating',creation_started=true where id=:'intent';
select lease as lease from public.hotel_payment_requests where id=:'intent' \gset
select throws_ok(format('select public.apply_online_payment(%L,%L,%L)',:'intent',:'lease',jsonb_set(pg_temp.snapshot(:'intent','Group150'),'{payment,amount}','1')),'22023',null,'mismatched captured amount cannot confirm any group rooms');
select public.apply_online_payment(:'intent',:'lease',pg_temp.snapshot(:'intent','Group150','created'));
select ok(exists(select 1 from public.messages where payment_request_id=:'intent'and body like'Pay one 50% group deposit%'and body like'%all 3 rooms%'),'one payment message covers all group rooms');
update public.hotel_payment_requests set lease=gen_random_uuid()where id=:'intent';
select public.apply_online_payment(:'intent',(select lease from public.hotel_payment_requests where id=:'intent'),pg_temp.snapshot(:'intent','Group150'));
select ok(not exists(select 1 from public.reservations where group_id=:'grp'and status<>'confirmed'),'verified deposit confirms every room together');
select is((select count(*)::integer from public.payments where online_request_id=:'intent'),3,'real capture recorded on all three individual folios');
select is((select sum(amount)from public.payments where online_request_id=:'intent'),12500.01::numeric,'no money duplicated by per-room allocation');
select is((select count(distinct provider_payment_id)::integer from public.payments where online_request_id=:'intent'),1,'one real provider transaction shared across room receipts');
select is((select count(*)::integer from public.whatsapp_automation_events where property_id=:'pid'and event_key='booking_confirmed'),1,'group generates one welcome, not three duplicates');
select is((select count(*)::integer from public.messages where payment_request_id=:'intent'and journey_purpose like'booking_summary:%'and body like'%Check-in:%from 13:00%'and body like'%Check-out:%by 11:30%'),1,'group confirmation provides check-in and check-out times');
select is(private.inbox_delivery_error((select receipt_message_id from public.hotel_payment_requests where id=:'intent')),null::text,'group confirmation passes delivery guards with multiple candidate stays');
update public.hotel_payment_requests set lease=gen_random_uuid()where id=:'intent';
select public.apply_online_payment(:'intent',(select lease from public.hotel_payment_requests where id=:'intent'),pg_temp.snapshot(:'intent','Group150'));
select is((select count(*)::integer from public.payments where online_request_id=:'intent'),3,'repeated verified callback cannot duplicate money');
select is((select count(*)::integer from public.messages where payment_request_id=:'intent'and journey_purpose like'booking_summary:%'),1,'repeated callback cannot repeat group confirmation');
select jsonb_build_array(jsonb_build_object('id','rfnd_Group150','payment_id','pay_Group150','amount',900001,'status','processed'))as refunds \gset
update public.hotel_payment_requests set lease=gen_random_uuid()where id=:'intent';
select public.apply_online_payment(:'intent',(select lease from public.hotel_payment_requests where id=:'intent'),pg_temp.snapshot(:'intent','Group150','paid',:'refunds'));
select is((select sum(r.amount)from public.refunds r join public.payments p on p.id=r.payment_id where p.online_request_id=:'intent'),9000.01::numeric,'verified group refund distributed across room payments exactly');
select ok(not exists(select 1 from public.payments p where p.online_request_id=:'intent'and p.amount<(select sum(amount)from public.refunds r where r.payment_id=p.id)),'no individual receipt is over-refunded');
update public.hotel_payment_requests set lease=gen_random_uuid()where id=:'intent';
select public.apply_online_payment(:'intent',(select lease from public.hotel_payment_requests where id=:'intent'),pg_temp.snapshot(:'intent','Group150','paid',:'refunds'));
select is((select sum(r.amount)from public.refunds r join public.payments p on p.id=r.payment_id where p.online_request_id=:'intent'),9000.01::numeric,'refund reconciliation is idempotent');
select throws_ok(format('select public.apply_online_payment(%L,(select lease from public.hotel_payment_requests where id=%L),%L)',:'intent',:'intent',pg_temp.snapshot(:'intent','Group150','paid',jsonb_build_array(jsonb_build_object('id','rfnd_TooMuch150','payment_id','pay_Group150','amount',9999999,'status','processed')))),'22023',null,'aggregate group refunds cannot exceed the deposit');
-- Unpaid groups release all rooms and late capture never recreates them.
select pg_temp.group_quote('919000001502',10)as expired_cid \gset
select pg_temp.incoming('919000001502',pg_temp.pick(:'expired_cid','enquiry_confirm'));
select reservation_id as expired_rid,payment_request_id as expired_intent,group_id as expired_grp from private.whatsapp_booking_sessions where conversation_id=:'expired_cid' \gset
update public.reservations set deposit_expires_at=now()-interval'1 second'where id=:'expired_rid';
select is(private.expire_whatsapp_deposits(),1,'one expired group hold is processed');
select is((select count(*)::integer from public.reservations where group_id=:'expired_grp'and status='cancelled'),3,'expiry cancels all provisional group rooms');
select is((select count(*)::integer from public.unit_holds h join public.reservations r on r.id=h.reservation_id where r.group_id=:'expired_grp'and h.active),0,'every expired room is available for another booking');
update public.hotel_payment_requests set lease=gen_random_uuid()where id=:'expired_intent';
select public.apply_online_payment(:'expired_intent',(select lease from public.hotel_payment_requests where id=:'expired_intent'),pg_temp.snapshot(:'expired_intent','LateGroup150'));
select is((select count(*)::integer from public.reservations where group_id=:'expired_grp'and status='confirmed'),0,'late group payment never confirms released rooms');
select is((select sum(amount)from public.payments where online_request_id=:'expired_intent'),9500.01::numeric,'late group money remains accounted for');
select ok((select last_error like'Group payment requires staff review:%'from public.hotel_payment_requests where id=:'expired_intent'),'late payment flags refund or rebooking review');
-- Inventory contention rolls back the complete group, including its newly created contact.
select pg_temp.group_quote('919000001506',30)as contention \gset
select room_items as contention_items from private.whatsapp_booking_sessions where conversation_id=:'contention' \gset
insert into public.guests(tenant_id,full_name,phone)values('f2000000-0000-0000-0000-000000000001','Other allocation','+919000099999')returning id as blocker_guest \gset
insert into public.reservations(tenant_id,property_id,guest_id,check_in,check_out,status,total_amount,currency)values('f2000000-0000-0000-0000-000000000001',:'pid',:'blocker_guest',((now()at time zone'Asia/Kolkata')::date+30),((now()at time zone'Asia/Kolkata')::date+32),'confirmed',100,'INR')returning id as blocker \gset
select private.frontdesk_allocate(:'pid','f2000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000001',(now()at time zone'Asia/Kolkata')::date+30,(now()at time zone'Asia/Kolkata')::date+32,:'blocker',null);
select private.frontdesk_allocate(:'pid','f2000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000001',(now()at time zone'Asia/Kolkata')::date+30,(now()at time zone'Asia/Kolkata')::date+32,:'blocker',null);
select private.frontdesk_allocate(:'pid','f2000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000001',(now()at time zone'Asia/Kolkata')::date+30,(now()at time zone'Asia/Kolkata')::date+32,:'blocker',null);
select pg_temp.incoming('919000001506',pg_temp.pick(:'contention','enquiry_confirm'));
select ok(not exists(select 1 from public.guests where phone='+919000001506'),'failed allocation rolls back the new group contact');
select is((select reservation_id from private.whatsapp_booking_sessions where conversation_id=:'contention'),null::uuid,'partial group creation cannot leak a lead reservation');
select ok(not exists(select 1 from public.reservation_groups where creation_request_id=(select id from private.whatsapp_booking_sessions where conversation_id=:'contention')),'failed group has no partial group header');
-- All holds must still be valid when capture finishes, even before the expiry job runs.
select pg_temp.group_quote('919000001507',40)as race \gset
select pg_temp.incoming('919000001507',pg_temp.pick(:'race','enquiry_confirm'));
select payment_request_id as race_intent,group_id as race_grp from private.whatsapp_booking_sessions where conversation_id=:'race' \gset
update public.reservations set deposit_expires_at=now()-interval'1 second'where group_id=:'race_grp';
update public.hotel_payment_requests set lease=gen_random_uuid()where id=:'race_intent';
select public.apply_online_payment(:'race_intent',(select lease from public.hotel_payment_requests where id=:'race_intent'),pg_temp.snapshot(:'race_intent','RaceGroup150'));
select is((select count(*)::integer from public.reservations where group_id=:'race_grp'and status='cancelled'),3,'late capture releases all rooms even before cron expiry');
select is((select count(*)::integer from public.whatsapp_automation_events where event_key='booking_confirmed'and reservation_id in(select id from public.reservations where group_id=:'race_grp')),0,'deadline race cannot emit a false group welcome');
-- Later settlement checks must not change a group already admitted by reception.
-- Admission itself is covered by journey tests; isolate reconciliation from that prerequisite here.
update public.whatsapp_journey_settings set enabled=false where property_id=:'pid';
update public.reservations set status='checked_in'where id=:'rid';
update public.whatsapp_journey_settings set enabled=true where property_id=:'pid';
update public.hotel_payment_requests set lease=gen_random_uuid()where id=:'intent';
select public.apply_online_payment(:'intent',(select lease from public.hotel_payment_requests where id=:'intent'),pg_temp.snapshot(:'intent','Group150','paid',:'refunds'));
select is((select status from public.reservations where id=:'rid'),'checked_in','reconciliation preserves an already checked-in room');
select is((select last_error from public.hotel_payment_requests where id=:'intent'),null::text,'an already confirmed group is not falsely flagged as an expired hold');
select is((select count(*)::integer from public.messages where payment_request_id=:'intent'and journey_purpose like'booking_summary:%'),1,'later reconciliation cannot repeat confirmation after check-in');
select ok(not has_function_privilege('authenticated','private.record_group_payment(uuid,jsonb,jsonb)','execute'),'browser cannot forge allocation receipts');

select *from finish();
rollback;
