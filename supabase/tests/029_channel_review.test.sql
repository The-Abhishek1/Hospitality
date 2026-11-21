begin;
select plan(33);

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


set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select set_config('test.channel',public.prepare_channel('c3000000-0000-0000-0000-000000000001','agoda','123','test')::text,true);
reset role;set local role service_role;
select public.approve_channel_sandbox(current_setting('test.channel')::uuid);
reset role;
create function pg_temp.review_event(event_key text,revision_at text,status_text text default 'ConfirmBooking',booking text default '9001')returns void language plpgsql as $$begin
 perform public.ingest_channel_event(current_setting('test.channel')::uuid,event_key,jsonb_build_object('type','agoda.snapshot','external_property_id','123','external_reservation_id',booking,'revision',revision_at,'status',status_text,'currency','INR','payment_model','property_collect','amount_basis','sell_inclusive_amt','total_amount','200.00','room_count',1,'external_room_id','456','check_in',current_date+30,'check_out',current_date+32,'adults',2,'children',0,'guest_name','Manual guest'));
 perform public.process_pending_channel_events();
end $$;
set local role service_role;
select pg_temp.review_event('initial','2026-11-17T01:00:00Z');
select set_config('test.case',(select id::text from public.channel_review_cases where connection_id=current_setting('test.channel')::uuid),true);
select is((select count(*)::int from public.channel_review_cases where connection_id=current_setting('test.channel')::uuid),1,'failed import creates a review case');
select is((select status from public.channel_review_cases where id=current_setting('test.case')::uuid),'open','case starts open');
reset role;set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select is_empty($$select 1 from public.channel_review_cases where id=current_setting('test.case')::uuid$$,'housekeeping cannot read case');
select throws_ok($$select public.channel_review_command('c3000000-0000-0000-0000-000000000001',current_setting('test.case')::uuid,1,gen_random_uuid(),'retry','{"reason":"Fixed mapping"}')$$,'42501',null,'housekeeping cannot resolve case');
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select public.channel_review_command('c3000000-0000-0000-0000-000000000002',current_setting('test.case')::uuid,1,gen_random_uuid(),'retry','{"reason":"Fixed mapping"}')$$,'P0002',null,'property parameter cannot redirect case action');
select lives_ok($$select public.channel_review_command('c3000000-0000-0000-0000-000000000001',current_setting('test.case')::uuid,1,'c7000000-0000-0000-0000-000000000001','retry','{"reason":"Fixed mapping"}')$$,'manager queues retry');
select lives_ok($$select public.channel_review_command('c3000000-0000-0000-0000-000000000001',current_setting('test.case')::uuid,1,'c7000000-0000-0000-0000-000000000001','retry','{"reason":"Fixed mapping"}')$$,'same command safely replays');
select is((select count(*)::int from public.channel_review_actions where case_id=current_setting('test.case')::uuid),1,'replay creates no duplicate audit action');
select throws_ok($$select public.channel_review_command('c3000000-0000-0000-0000-000000000001',current_setting('test.case')::uuid,1,'c7000000-0000-0000-0000-000000000001','retry','{"reason":"Different reason"}')$$,'22023',null,'reused request with different payload rejected');
select throws_ok($$select public.channel_review_command('c3000000-0000-0000-0000-000000000001',current_setting('test.case')::uuid,1,gen_random_uuid(),'retry','{"reason":"Another attempt"}')$$,'40001',null,'stale version rejected');
reset role;set local role service_role;
select is((select status from public.channel_events where connection_id=current_setting('test.channel')::uuid and external_event_id='initial'),'received','retry requeues durable event');
select public.process_pending_channel_events();
reset role;set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select public.channel_review_command('c3000000-0000-0000-0000-000000000001',current_setting('test.case')::uuid,2,gen_random_uuid(),'resolve_manual','{"reason":"Handled with provider"}')$$,'22023',null,'manual resolution needs explicit confirmation');
select lives_ok($$select public.channel_review_command('c3000000-0000-0000-0000-000000000001',current_setting('test.case')::uuid,2,gen_random_uuid(),'resolve_manual','{"reason":"Handled with provider","confirmed":true}')$$,'manual resolution recorded');
select is((select management_mode from public.channel_review_cases where id=current_setting('test.case')::uuid),'manual','manual handling is sticky');
select is((select status from public.channel_review_cases where id=current_setting('test.case')::uuid),'resolved','current revision resolved');
reset role;set local role service_role;
select pg_temp.review_event('duplicate','2026-11-17T01:00:00Z');
select is((select status from public.channel_review_cases where id=current_setting('test.case')::uuid),'resolved','duplicate same revision does not reopen resolved case');
select pg_temp.review_event('new-revision','2026-11-18T01:00:00Z','AmendBooking');
select is((select status from public.channel_review_cases where id=current_setting('test.case')::uuid),'open','newer revision reopens manual case');
select is((select count(*)::int from public.reservations where property_id='c3000000-0000-0000-0000-000000000001'and channel_ref='agoda:9001'),0,'manual mode prevents automatic duplicate import');
reset role;set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select public.channel_review_command('c3000000-0000-0000-0000-000000000001',current_setting('test.case')::uuid,(select version from public.channel_review_cases where id=current_setting('test.case')::uuid),gen_random_uuid(),'retry','{"reason":"Try automatic again"}')$$,'22023',null,'manual booking cannot return to unsafe automatic import');
select public.map_channel_room(current_setting('test.channel')::uuid,'c4000000-0000-0000-0000-000000000001','456');
select set_config('test.reservation',public.create_reservation('c3000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000001','c4000000-0000-0000-0000-000000000001',current_date+30,current_date+32,2,0)::text,true);
reset role;set local role service_role;
insert into public.reservations(id,tenant_id,property_id,guest_id,check_in,check_out,adults,total_amount,currency)
values('c8000000-0000-0000-0000-000000000001','c2000000-0000-0000-0000-000000000001','c3000000-0000-0000-0000-000000000002','c5000000-0000-0000-0000-000000000001',current_date+30,current_date+32,2,200,'INR');
reset role;set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select public.channel_review_command('c3000000-0000-0000-0000-000000000001',current_setting('test.case')::uuid,(select version from public.channel_review_cases where id=current_setting('test.case')::uuid),gen_random_uuid(),'link','{"reason":"Verified candidate reservation","confirmed":true,"reservation_id":"c8000000-0000-0000-0000-000000000001"}')$$,'22023',null,'cannot link another hotel reservation');
select lives_ok($$select public.channel_review_command('c3000000-0000-0000-0000-000000000001',current_setting('test.case')::uuid,(select version from public.channel_review_cases where id=current_setting('test.case')::uuid),'c7000000-0000-0000-0000-000000000002','link',jsonb_build_object('reason','Verified all booking details','confirmed',true,'reservation_id',current_setting('test.reservation')))$$,'verified reservation links');
select is((select channel_ref from public.reservations where id=current_setting('test.reservation')::uuid),'agoda:9001','provider reference attached');
select is((select total_amount from public.reservations where id=current_setting('test.reservation')::uuid),200::numeric,'link preserves financial amount');
select is((select reservation_id::text from public.channel_review_cases where id=current_setting('test.case')::uuid),current_setting('test.reservation'),'case points to local stay');
select is((select count(*)::int from public.reservation_events where reservation_id=current_setting('test.reservation')::uuid and event_type='channel_linked_manually'),1,'link has reservation audit event');
select is((select count(*)::int from public.folios where reservation_id=current_setting('test.reservation')::uuid),0,'link posts no charges or payments');
reset role;set local role service_role;
select pg_temp.review_event('after-link','2026-11-19T01:00:00Z','AmendBooking');
select is((select status from public.channel_review_cases where id=current_setting('test.case')::uuid),'open','linked booking future changes reopen case');
select is((select count(*)::int from public.reservations where property_id='c3000000-0000-0000-0000-000000000001'and channel_ref='agoda:9001'),1,'linked booking never duplicated');

-- A corrected automatic retry resolves its case and exposes the imported reservation.
delete from public.channel_unit_mappings where connection_id=current_setting('test.channel')::uuid;
select pg_temp.review_event('auto-fix','2026-11-19T01:00:00Z','ConfirmBooking','9002');
select set_config('test.auto_case',(select id::text from public.channel_review_cases where connection_id=current_setting('test.channel')::uuid and external_reservation_id='9002'),true);
reset role;set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select public.map_channel_room(current_setting('test.channel')::uuid,'c4000000-0000-0000-0000-000000000001','456');
select public.channel_review_command('c3000000-0000-0000-0000-000000000001',current_setting('test.auto_case')::uuid,1,gen_random_uuid(),'retry','{"reason":"Corrected the room mapping"}');
reset role;set local role service_role;
select public.process_pending_channel_events();
select is((select status from public.channel_review_cases where id=current_setting('test.auto_case')::uuid),'resolved','successful retry resolves case');
select ok((select reservation_id is not null from public.channel_review_cases where id=current_setting('test.auto_case')::uuid),'resolved automatic case links imported reservation');
select is((select management_mode from public.channel_review_cases where id=current_setting('test.auto_case')::uuid),'automatic','successful retry retains normal automatic handling');
reset role;set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select public.channel_review_command('c3000000-0000-0000-0000-000000000001',current_setting('test.case')::uuid,(select version from public.channel_review_cases where id=current_setting('test.case')::uuid),gen_random_uuid(),'resolve_manual','{"reason":"Verified provider changes","confirmed":true}');
reset role;set local role service_role;
select pg_temp.review_event('same-time-conflict','2026-11-19T01:00:00Z','CancelBooking');
select is((select status from public.channel_review_cases where id=current_setting('test.case')::uuid),'open','conflicting status at same timestamp reopens manual case');
select is((select status from public.reservations where id=current_setting('test.reservation')::uuid),'confirmed','review never silently cancels the linked stay');
select * from finish();rollback;
