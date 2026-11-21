begin;
select plan(36);

insert into auth.users (id, email) values
  ('c1000000-0000-0000-0000-000000000001', 'owner@t11.test'), ('c1000000-0000-0000-0000-000000000002', 'hk@t11.test');
insert into public.tenants (id, name, slug) values ('c2000000-0000-0000-0000-000000000001', 'Tenant 11', 'tenant-11');
insert into public.properties (id, tenant_id, name, property_type) values
  ('c3000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000001', 'Prop 11', 'hotel'),
  ('c3000000-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000001', 'Prop 11b', 'hotel');
insert into public.tenant_memberships (tenant_id, user_id, role) values
  ('c2000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'owner'),
  ('c2000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000002', 'member');
insert into public.property_memberships (property_id, tenant_id, user_id) values
  ('c3000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000002');
insert into public.user_roles (property_id, user_id, role_id)
select 'c3000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000002', id from public.roles where key = 'housekeeping' and tenant_id is null;
insert into public.accommodation_types (id, tenant_id, property_id, name, max_occupancy, base_rate) values
  ('c4000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-000000000001', 'Std', 2, 100),
  ('c4000000-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-000000000002', 'Other', 2, 100);
insert into public.accommodation_units (tenant_id, property_id, type_id, name) values
  ('c2000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-000000000001', 'c4000000-0000-0000-0000-000000000001', 'D1'),
  ('c2000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-000000000001', 'c4000000-0000-0000-0000-000000000001', 'D2');
insert into public.guests (id, tenant_id, full_name) values ('c5000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000001', 'Direct Guest');

insert into public.rate_plans(id,tenant_id,property_id,name,code,adjustment_percent) values('c6000000-0000-0000-0000-000000000001','c2000000-0000-0000-0000-000000000001','c3000000-0000-0000-0000-000000000001','Room only','ROOM',0);
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select public.prepare_channel('c3000000-0000-0000-0000-000000000001','agoda','123','agoda-test');
select public.map_channel_room((select id from public.channel_connections),'c4000000-0000-0000-0000-000000000001','456');
reset role;set local role service_role;
select public.approve_channel_sandbox((select id from public.channel_connections));
select lives_ok($$select public.save_channel_products((select id from public.channel_connections),'{"hotelId":"123","currency":"INR","rooms":[{"id":"456","name":"Double","capacity":2,"minRate":"10.00","maxRate":"1000.00"}],"rates":[{"id":"789","master":"0","name":"Room only"}],"products":[{"roomId":"456","rateId":"789"}]}')$$,'products saved');
select throws_ok($$select public.save_channel_products((select id from public.channel_connections),'{"hotelId":"999"}')$$,null,null,'reject wrong hotel products');
reset role;set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select public.map_channel_rate((select id from public.channel_connections),'c6000000-0000-0000-0000-000000000001','789')$$,'map known master rate');
select is(public.set_channel_rates((select id from public.channel_connections),'c4000000-0000-0000-0000-000000000001','c6000000-0000-0000-0000-000000000001',current_date+1,current_date+3,100.05,true,null,false,2,5),2,'calendar uses exclusive end');
select throws_ok($$select public.set_channel_rates((select id from public.channel_connections),'c4000000-0000-0000-0000-000000000001','c6000000-0000-0000-0000-000000000001',current_date+1,current_date+3,0.01)$$,'22023',null,'provider minimum price enforced');
select throws_ok($$select public.set_channel_rates((select id from public.channel_connections),'c4000000-0000-0000-0000-000000000001','c6000000-0000-0000-0000-000000000001',current_date+1,current_date+3,100.001)$$,'22023',null,'no silent amount rounding');
select throws_ok($$select public.map_channel_rate((select id from public.channel_connections),'c6000000-0000-0000-0000-000000000001','789')$$,'22023',null,'calendar mappings cannot change silently');
reset role;set local role service_role;
select is(jsonb_array_length(public.channel_rates_range((select id from public.channel_connections),'c4000000-0000-0000-0000-000000000001',current_date,current_date+10)),1,'worker receives one rate push');
select is(public.channel_rates_range((select id from public.channel_connections),'c4000000-0000-0000-0000-000000000001',current_date,current_date+10)->0->'days'->0->>'amount','100.05','exact rate preserved');
select set_config('test.poll',public.claim_channel_poll()::text,true);
select ok((current_setting('test.poll')::jsonb)->>'lease' is not null,'poll claimed');
select is(public.claim_channel_poll(),null::jsonb,'poll not handed out twice');
select is(public.complete_channel_poll((select id from public.channel_connections),gen_random_uuid(),now(),true),false,'stale poll lease rejected');
select is(public.complete_channel_poll((select id from public.channel_connections),(current_setting('test.poll')::jsonb->>'lease')::uuid,(current_setting('test.poll')::jsonb->>'to')::timestamptz,false,'timeout'),true,'poll failure persisted');
select ok((select cursor_at<(current_setting('test.poll')::jsonb->>'to')::timestamptz from public.channel_poll_state),'failed poll retains cursor');

-- Snapshots are full state. A modification can be the first observed revision.
select public.ingest_channel_event((select id from public.channel_connections),'a1',jsonb_build_object('type','agoda.snapshot','external_property_id','123','external_reservation_id','9001','revision','2026-11-17T00:00:00Z','status','AmendBooking','currency','INR','payment_model','property_collect','total_amount','200.05','room_count',1,'external_room_id','456','check_in',current_date+30,'check_out',current_date+32,'adults',2,'children',0,'guest_name','Test guest'));
select public.process_pending_channel_events();
select is((select count(*)::int from public.reservations where channel_ref='agoda:9001'),1,'first amendment imports full snapshot');
select is((select total_amount from public.reservations where channel_ref='agoda:9001'),200.05::numeric,'provider amount preserved');
select public.ingest_channel_event((select id from public.channel_connections),'older',jsonb_build_object('type','agoda.snapshot','external_property_id','123','external_reservation_id','9001','revision','2026-11-16T00:00:00Z','status','ConfirmBooking'));
select public.process_pending_channel_events();
select is((select status from public.channel_events where external_event_id='older'),'processed','older revision ignored');
-- An unfulfillable amendment preserves both prior dates and the original hold.
insert into public.unit_holds(tenant_id,property_id,unit_id,during,kind,reason)
select tenant_id,property_id,id,daterange(current_date+40,current_date+42,'[)'),'block','Maintenance test' from public.accommodation_units where property_id='c3000000-0000-0000-0000-000000000001';
select public.ingest_channel_event((select id from public.channel_connections),'blocked-amendment',jsonb_build_object('type','agoda.snapshot','external_property_id','123','external_reservation_id','9001','revision','2026-11-17T01:00:00Z','status','AmendBooking','currency','INR','payment_model','property_collect','total_amount','250.00','room_count',1,'external_room_id','456','check_in',current_date+40,'check_out',current_date+42,'adults',2,'children',0));
select public.process_pending_channel_events();
select is((select status from public.channel_events where external_event_id='blocked-amendment'),'failed','overbooking amendment enters review');
select is((select check_in from public.reservations where channel_ref='agoda:9001'),current_date+30,'failed amendment preserves dates');
select is((select count(*)::int from public.unit_holds h join public.reservations r on r.id=h.reservation_id where r.channel_ref='agoda:9001' and h.active),1,'failed amendment preserves active allocation');
select public.ingest_channel_event((select id from public.channel_connections),'multiroom',jsonb_build_object('type','agoda.snapshot','external_property_id','123','external_reservation_id','9006','revision','2026-11-17T00:00:00Z','status','ConfirmBooking','currency','INR','payment_model','property_collect','room_count',2));
select public.process_pending_channel_events();
select ok((select error like 'Multi-room%' from public.channel_events where external_event_id='multiroom'),'multi-room remains a review case');
select is((select count(*)::int from public.reservations where channel_ref='agoda:9006'),0,'multi-room is not silently imported as one room');
select public.ingest_channel_event((select id from public.channel_connections),'wrong-currency',jsonb_build_object('type','agoda.snapshot','external_property_id','123','external_reservation_id','9002','revision','2026-11-17T00:00:00Z','status','ConfirmBooking','currency','USD'));
select public.process_pending_channel_events();
select is((select status from public.channel_events where external_event_id='wrong-currency'),'failed','currency mismatch goes to review');
select public.ingest_channel_event((select id from public.channel_connections),'collect',jsonb_build_object('type','agoda.snapshot','external_property_id','123','external_reservation_id','9003','revision','2026-11-17T00:00:00Z','status','ConfirmBooking','currency','INR','payment_model','agoda_collect'));
select public.process_pending_channel_events();
select ok((select error like 'Agoda Collect%' from public.channel_events where external_event_id='collect'),'OTA collected money never becomes guest debt');
select public.ingest_channel_event((select id from public.channel_connections),'cancel',jsonb_build_object('type','agoda.snapshot','external_property_id','123','external_reservation_id','9001','revision','2026-11-18T00:00:00Z','status','CancelBooking','currency','INR'));
select public.process_pending_channel_events();
select is((select status from public.reservations where channel_ref='agoda:9001'),'cancelled','newer cancellation applied');
select is((select count(*)::int from public.unit_holds h join public.reservations r on r.id=h.reservation_id where r.channel_ref='agoda:9001' and h.active),0,'cancel releases inventory');
select public.ingest_channel_event((select id from public.channel_connections),'cancel-first',jsonb_build_object('type','agoda.snapshot','external_property_id','123','external_reservation_id','9004','revision','2026-11-18T00:00:00Z','status','CancelBooking','currency','INR'));
select public.process_pending_channel_events();
select is((select provider_status from public.channel_booking_state where external_reservation_id='9004'),'CancelBooking','cancellation before booking stores tombstone');
select public.ingest_channel_event((select id from public.channel_connections),'old-create',jsonb_build_object('type','agoda.snapshot','external_property_id','123','external_reservation_id','9004','revision','2026-11-17T00:00:00Z','status','ConfirmBooking'));
select public.process_pending_channel_events();
select is((select count(*)::int from public.reservations where channel_ref='agoda:9004'),0,'late create cannot resurrect cancelled booking');
select is((select status from public.channel_events where external_event_id='old-create'),'processed','late create resolved idempotently');

update public.channel_poll_state set next_poll_at=now();
select set_config('test.success_poll',public.claim_channel_poll()::text,true);
select is(public.complete_channel_poll((select id from public.channel_connections),(current_setting('test.success_poll')::jsonb->>'lease')::uuid,(current_setting('test.success_poll')::jsonb->>'to')::timestamptz,true),true,'durable successful poll advances checkpoint');
select is((select cursor_at from public.channel_poll_state),(current_setting('test.success_poll')::jsonb->>'to')::timestamptz,'checkpoint equals completed window end');
-- Reconfiguration invalidates a claimed cursor; mapped hotel IDs cannot be swapped.
update public.channel_poll_state set next_poll_at=now();
select set_config('test.poll2',public.claim_channel_poll()::text,true);
update public.channel_connections set status='paused';
select is(public.complete_channel_poll((select id from public.channel_connections),(current_setting('test.poll2')::jsonb->>'lease')::uuid,(current_setting('test.poll2')::jsonb->>'to')::timestamptz,true),false,'pause invalidates pending checkpoint');
select throws_ok($$update public.channel_connections set external_property_id='999'$$,'22023',null,'mapped hotel cannot silently change');
reset role;set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select is_empty($$select 1 from public.channel_products$$,'housekeeping cannot read provider products');
select is_empty($$select 1 from public.channel_rate_calendar$$,'housekeeping cannot read channel pricing');
select throws_ok($$select public.claim_channel_poll()$$,'42501',null,'hotel staff cannot claim provider polls');
select * from finish();rollback;
