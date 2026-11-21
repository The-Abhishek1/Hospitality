begin;
select plan(18);

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
select set_config('request.jwt.claims', '{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$select public.prepare_channel('c3000000-0000-0000-0000-000000000001','agoda','123','agoda-test')$$,'owner can prepare Agoda');
select is((select status from public.channel_connections where provider='agoda'),'paused','preparation never activates traffic');
select is((select sandbox_approved from public.channel_connections where provider='agoda'),false,'no implicit sandbox approval');
select throws_ok($$select public.connect_channel('c3000000-0000-0000-0000-000000000001','agoda')$$,'22023',null,'legacy API cannot bypass approval');
select throws_ok($$select public.approve_channel_sandbox((select id from public.channel_connections where provider='agoda'))$$,'42501',null,'hotel owner cannot approve traffic');
select throws_ok($$select public.prepare_channel('c3000000-0000-0000-0000-000000000001','booking_com','not-an-id')$$,'22023',null,'invalid provider ID rejected');
select lives_ok($$select public.map_channel_room((select id from public.channel_connections where provider='agoda'),'c4000000-0000-0000-0000-000000000001','456')$$,'map prepared hotel');
reset role; set local role service_role;
select is((select count(*)::int from public.claim_sync_jobs_v2()),0,'paused jobs not claimed');
select lives_ok($$select public.approve_channel_sandbox((select id from public.channel_connections where provider='agoda'))$$,'operator approves sandbox');
select is((select count(*)::int from public.claim_sync_jobs()),0,'legacy worker cannot claim real provider jobs');
select is((select count(*)::int from public.claim_sync_jobs_v2()),1,'approved sandbox job claimed');
select is(public.complete_sync_job_v2((select id from public.sync_jobs),gen_random_uuid(),true),false,'stale completion cannot acknowledge job');
select is((select status from public.sync_jobs),'running','wrong lease preserves running job');
select set_config('test.old_lease',(select lease_token::text from public.sync_jobs),true);
update public.sync_jobs set locked_at=now()-interval '6 minutes';
select is((select count(*)::int from public.claim_sync_jobs_v2()),1,'expired job can be reclaimed');
select isnt((select lease_token::text from public.sync_jobs),current_setting('test.old_lease'),'reclaim rotates lease token');
select is(public.complete_sync_job_v2((select id from public.sync_jobs),current_setting('test.old_lease')::uuid,true),false,'old worker cannot complete reclaimed attempt');
select is(public.complete_sync_job_v2((select id from public.sync_jobs),(select lease_token from public.sync_jobs),true),true,'current lease can complete');
select is((select status from public.sync_jobs),'succeeded','successful completion persisted');
select * from finish();
rollback;
