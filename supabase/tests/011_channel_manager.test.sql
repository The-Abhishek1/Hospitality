begin;
select plan(42);

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

-- configuration
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$select public.connect_channel('c3000000-0000-0000-0000-000000000001', 'mock', 'vault:mock')$$, 'connect the mock channel');
select lives_ok($$select public.map_channel_room((select id from public.channel_connections limit 1), 'c4000000-0000-0000-0000-000000000001', 'R-STD')$$, 'map a room type');
select throws_ok($$select public.map_channel_room((select id from public.channel_connections limit 1), 'c4000000-0000-0000-0000-000000000002', 'R-OTHER')$$, '22023', null, 'cannot map another property''s room type');
select set_config('request.jwt.claims', '{"sub":"c1000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select throws_ok($$select public.connect_channel('c3000000-0000-0000-0000-000000000001', 'mock')$$, '42501', null, 'staff without permission cannot connect channels');

-- the initial picture is pushed once
reset role; set local role service_role;
select is((select count(*)::int from public.claim_sync_jobs(5)), 1, 'mapping enqueued an initial sync');
do $$ begin perform public.complete_sync_job((select id from public.sync_jobs where status = 'running'), true); end $$;
select is((select status from public.sync_jobs), 'succeeded', 'initial sync completed');

-- bookings enqueue coalesced availability jobs
reset role; set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$select public.create_reservation('c3000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000001','c4000000-0000-0000-0000-000000000001','2027-06-01','2027-06-03',1,0,null,'direct','D-1')$$, 'direct booking 1');
select is((select count(*)::int from public.sync_jobs where status = 'queued'), 1, 'booking queued one availability job');
select lives_ok($$select public.create_reservation('c3000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000001','c4000000-0000-0000-0000-000000000001','2027-06-02','2027-06-05',1,0,null,'direct','D-2')$$, 'direct booking 2');
select is((select count(*)::int from public.sync_jobs where status = 'queued'), 1, 'second booking widened the queued job instead of adding one');
select is((select date_from::text || '..' || date_to::text from public.sync_jobs where status = 'queued'), '2027-06-01..2027-06-05', 'job range covers both stays');

reset role; set local role service_role;
select is((select available from public.channel_availability_range((select id from public.channel_connections limit 1), '2027-06-01', '2027-06-06') where day = '2027-06-02'), 0, 'fully booked night shows 0');
select is((select available from public.channel_availability_range((select id from public.channel_connections limit 1), '2027-06-01', '2027-06-06') where day = '2027-06-01'), 1, 'one unit free');
select is((select available from public.channel_availability_range((select id from public.channel_connections limit 1), '2027-06-01', '2027-06-06') where day = '2027-06-05'), 2, 'untouched night shows 2 (checkout day is free)');

-- worker: claim, retry/backoff, dead letter
select is((select count(*)::int from public.claim_sync_jobs(5)), 1, 'worker claims the job');
select is((select count(*)::int from public.claim_sync_jobs(5)), 0, 'claimed job is not handed out twice');
do $$ begin perform public.complete_sync_job((select id from public.sync_jobs where status = 'running'), false, 'provider timeout'); end $$;
select is((select status from public.sync_jobs where status <> 'succeeded'), 'queued', 'failed push is re-queued');
select ok((select next_attempt_at > now() from public.sync_jobs where status = 'queued'), 'with backoff');
update public.sync_jobs set next_attempt_at = now() where status = 'queued';
do $$ begin
  perform count(*) from public.claim_sync_jobs(5);
  update public.sync_jobs set attempts = 5 where status = 'running';
  perform public.complete_sync_job((select id from public.sync_jobs where status = 'running'), false, 'still failing');
end $$;
select is((select count(*)::int from public.sync_jobs where status = 'dead'), 1, 'dead-lettered after max attempts');

-- resync request and success path
reset role; set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(public.request_channel_resync((select id from public.channel_connections limit 1), 30), 1, 'owner requests a resync');
reset role; set local role service_role;
do $$ begin
  perform count(*) from public.claim_sync_jobs(5);
  perform public.complete_sync_job((select id from public.sync_jobs where status = 'running'), true);
end $$;
select is((select count(*)::int from public.sync_attempts where ok), 2, 'successful pushes are logged');

-- reconciliation against the mock provider
do $$ declare r record; begin
  for r in select * from public.channel_availability_range((select id from public.channel_connections limit 1), '2027-06-01', '2027-06-06') loop
    perform public.mock_provider_push((select id from public.channel_connections limit 1), r.external_room_id, r.day, case when r.day = '2027-06-02' then 9 else r.available end);
  end loop;
end $$;
select is((select count(*)::int from public.mock_reconcile((select id from public.channel_connections limit 1), '2027-06-01', '2027-06-06')), 1, 'reconciliation finds exactly the drifted night');
select is((select day::text from public.mock_reconcile((select id from public.channel_connections limit 1), '2027-06-01', '2027-06-06')), '2027-06-02', 'and names it');

-- mock provider event feed
do $$ begin perform public.mock_ota_emit((select id from public.channel_connections limit 1), '{"hello":"world"}'::jsonb); end $$;
select is((select count(*)::int from public.mock_ota_poll((select id from public.channel_connections limit 1))), 1, 'poll returns emitted events');
select is((select count(*)::int from public.mock_ota_poll((select id from public.channel_connections limit 1))), 0, 'and drains them');

-- inbound reservation events
select ok(public.ingest_channel_event((select id from public.channel_connections limit 1), 'E1',
  '{"type":"reservation.created","external_reservation_id":"EXT-1","external_room_id":"R-STD","check_in":"2027-07-01","check_out":"2027-07-03","adults":2,"children":0,"guest_name":"Ota Guest","guest_phone":"+9100","total_amount":333.50}'::jsonb) is not null, 'event ingested');
select is(public.ingest_channel_event((select id from public.channel_connections limit 1), 'E1', '{}'::jsonb), null, 'duplicate delivery ignored');
select is(public.process_pending_channel_events(), 1, 'worker processes pending events');
select is((select count(*)::int from public.reservations where channel_ref = 'mock:EXT-1' and source = 'ota' and status = 'confirmed' and total_amount = 333.50), 1, 'OTA reservation created with the OTA total');
do $$ begin
  perform public.ingest_channel_event((select id from public.channel_connections limit 1), 'E1b',
    '{"type":"reservation.created","external_reservation_id":"EXT-1","external_room_id":"R-STD","check_in":"2027-07-01","check_out":"2027-07-03","adults":2,"children":0,"guest_name":"Ota Guest","total_amount":333.50}'::jsonb);
  perform public.process_pending_channel_events();
end $$;
select is((select count(*)::int from public.reservations where channel_ref = 'mock:EXT-1'), 1, 'same booking under a new event id is idempotent');

do $$ begin
  perform public.ingest_channel_event((select id from public.channel_connections limit 1), 'E2',
    '{"type":"reservation.modified","external_reservation_id":"EXT-1","external_room_id":"R-STD","check_in":"2027-07-02","check_out":"2027-07-04","adults":2,"children":0,"total_amount":400}'::jsonb);
  perform public.process_pending_channel_events();
end $$;
select is((select check_out::text from public.reservations where channel_ref = 'mock:EXT-1'), '2027-07-04', 'modification applied');
select is((select count(*)::int from public.unit_holds h join public.reservations r on r.id = h.reservation_id where r.channel_ref = 'mock:EXT-1' and h.active), 1, 'exactly one active hold after modification');

do $$ begin
  perform public.ingest_channel_event((select id from public.channel_connections limit 1), 'E3',
    '{"type":"reservation.cancelled","external_reservation_id":"EXT-1"}'::jsonb);
  perform public.process_pending_channel_events();
end $$;
select is((select status from public.reservations where channel_ref = 'mock:EXT-1'), 'cancelled', 'cancellation applied');
select is((select count(*)::int from public.unit_holds h join public.reservations r on r.id = h.reservation_id where r.channel_ref = 'mock:EXT-1' and h.active), 0, 'inventory released');

-- overbooking safety, unmapped rooms, out-of-order events
reset role; set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
do $$ begin
  perform public.create_reservation('c3000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000001','c4000000-0000-0000-0000-000000000001','2027-08-01','2027-08-03',1,0,null,'direct','F-1');
  perform public.create_reservation('c3000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000001','c4000000-0000-0000-0000-000000000001','2027-08-01','2027-08-03',1,0,null,'direct','F-2');
end $$;
reset role; set local role service_role;
do $$ begin
  perform public.ingest_channel_event((select id from public.channel_connections limit 1), 'E4',
    '{"type":"reservation.created","external_reservation_id":"EXT-2","external_room_id":"R-STD","check_in":"2027-08-01","check_out":"2027-08-03","adults":1,"children":0}'::jsonb);
  perform public.ingest_channel_event((select id from public.channel_connections limit 1), 'E5',
    '{"type":"reservation.created","external_reservation_id":"EXT-3","external_room_id":"R-NOPE","check_in":"2027-09-01","check_out":"2027-09-03"}'::jsonb);
  perform public.ingest_channel_event((select id from public.channel_connections limit 1), 'E6',
    '{"type":"reservation.modified","external_reservation_id":"EXT-404","external_room_id":"R-STD","check_in":"2027-10-01","check_out":"2027-10-03"}'::jsonb);
  perform public.process_pending_channel_events();
end $$;
select is((select status from public.channel_events where external_event_id = 'E4'), 'failed', 'booking on a full house fails visibly');
select ok((select error like 'no availability%' from public.channel_events where external_event_id = 'E4'), 'with a clear reason');
select is((select count(*)::int from public.reservations where channel_ref = 'mock:EXT-2'), 0, 'and no reservation or hold is left behind');
select ok((select error like 'unmapped room%' from public.channel_events where external_event_id = 'E5'), 'unmapped room is reported');
select ok((select status = 'failed' and attempts = 1 and next_attempt_at > now() from public.channel_events where external_event_id = 'E6'), 'out-of-order modification waits for a retry');

-- visibility
reset role; set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select ok((select count(*) from public.channel_events) >= 5, 'managers see channel events');
select set_config('request.jwt.claims', '{"sub":"c1000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select is_empty($$select 1 from public.channel_events$$, 'other staff do not');
select throws_ok($$select public.ingest_channel_event((select id from public.channel_connections limit 1), 'X', '{}'::jsonb)$$, '42501', null, 'staff cannot inject channel events');

select * from finish();
rollback;
