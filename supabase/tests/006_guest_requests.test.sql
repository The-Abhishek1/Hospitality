begin;
select plan(18);

insert into auth.users (id, email) values
  ('71000000-0000-0000-0000-000000000001', 'owner@t6.test'), ('71000000-0000-0000-0000-000000000002', 'clerk@t6.test'),
  ('71000000-0000-0000-0000-000000000003', 'hk1@t6.test'),   ('71000000-0000-0000-0000-000000000004', 'hk2@t6.test');
insert into public.tenants (id, name, slug) values ('72000000-0000-0000-0000-000000000001', 'Tenant 6', 'tenant-6');
insert into public.properties (id, tenant_id, name, property_type) values
  ('73000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', 'Prop 6', 'hotel');
insert into public.tenant_memberships (tenant_id, user_id, role)
select '72000000-0000-0000-0000-000000000001', u, case when u = '71000000-0000-0000-0000-000000000001' then 'owner' else 'member' end
from (values ('71000000-0000-0000-0000-000000000001'::uuid), ('71000000-0000-0000-0000-000000000002'),
             ('71000000-0000-0000-0000-000000000003'), ('71000000-0000-0000-0000-000000000004')) v(u);
insert into public.property_memberships (property_id, tenant_id, user_id)
select '73000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', u
from (values ('71000000-0000-0000-0000-000000000002'::uuid), ('71000000-0000-0000-0000-000000000003'), ('71000000-0000-0000-0000-000000000004')) v(u);
insert into public.user_roles (property_id, user_id, role_id)
select '73000000-0000-0000-0000-000000000001', v.u, r.id
from (values ('71000000-0000-0000-0000-000000000002'::uuid, 'front_desk'), ('71000000-0000-0000-0000-000000000003', 'housekeeping'),
             ('71000000-0000-0000-0000-000000000004', 'housekeeping')) v(u, k)
join public.roles r on r.key = v.k and r.tenant_id is null;
insert into public.accommodation_types (id, tenant_id, property_id, name, max_occupancy, base_rate) values
  ('74000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', '73000000-0000-0000-0000-000000000001', 'Std', 2, 100);
insert into public.accommodation_units (tenant_id, property_id, type_id, name) values
  ('72000000-0000-0000-0000-000000000001', '73000000-0000-0000-0000-000000000001', '74000000-0000-0000-0000-000000000001', 'U1');
insert into public.guests (id, tenant_id, full_name) values ('75000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', 'Guest');
insert into public.service_categories (id, tenant_id, property_id, name) values
  ('76000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', '73000000-0000-0000-0000-000000000001', 'Amenities');
insert into public.service_catalog (id, tenant_id, property_id, category_id, name) values
  ('77000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', '73000000-0000-0000-0000-000000000001', '76000000-0000-0000-0000-000000000001', 'Extra towels'),
  ('77000000-0000-0000-0000-000000000002', '72000000-0000-0000-0000-000000000001', '73000000-0000-0000-0000-000000000001', '76000000-0000-0000-0000-000000000001', 'Late checkout');
insert into public.service_routing_rules (tenant_id, property_id, catalog_id, task_kind, default_assignee_id, sla_minutes) values
  ('72000000-0000-0000-0000-000000000001', '73000000-0000-0000-0000-000000000001', '77000000-0000-0000-0000-000000000001', 'housekeeping', '71000000-0000-0000-0000-000000000003', 30);

-- in-house guest (booked and checked in by the owner)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"71000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
do $$ begin
  perform public.create_reservation('73000000-0000-0000-0000-000000000001','75000000-0000-0000-0000-000000000001','74000000-0000-0000-0000-000000000001','2027-10-01','2027-10-04',1,0,null,'direct','G1');
  perform public.check_in_reservation((select id from public.reservations where channel_ref='G1'));
end $$;

-- front desk raises a request; routing rule creates a linked task for hk1
select set_config('request.jwt.claims', '{"sub":"71000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select lives_ok($$select public.create_guest_request('73000000-0000-0000-0000-000000000001', (select id from public.reservations where channel_ref='G1'), '77000000-0000-0000-0000-000000000001', null, '2 extra towels')$$, 'create routed request');
select is((select count(*)::int from public.guest_requests where status='new'), 1, 'request is new');

-- hk1: sees the linked task and the request it belongs to
select set_config('request.jwt.claims', '{"sub":"71000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select is((select count(*)::int from public.tasks where guest_request_id is not null), 1, 'assignee sees linked task');
select is((select count(*)::int from public.guest_requests), 1, 'assignee sees the request via the task');
select lives_ok($$select public.set_task_status((select id from public.tasks where guest_request_id is not null), 'in_progress')$$, 'task started');
select is((select status from public.guest_requests limit 1), 'in_progress', 'request follows task to in_progress');
select lives_ok($$select public.set_task_status((select id from public.tasks where guest_request_id is not null), 'done')$$, 'task done');
select is((select status from public.guest_requests limit 1), 'completed', 'request completes with its task');
select throws_ok($$select public.create_guest_request('73000000-0000-0000-0000-000000000001', (select id from public.reservations where channel_ref='G1'), null, 'Sneaky')$$, '42501', null, 'housekeeper cannot raise requests');

-- hk2: unrelated housekeeper sees nothing
select set_config('request.jwt.claims', '{"sub":"71000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
select is_empty($$select 1 from public.guest_requests$$, 'unrelated staff cannot see requests');

-- front desk: feedback, no-rule request, cancellation
select set_config('request.jwt.claims', '{"sub":"71000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select throws_ok($$select public.record_guest_request_feedback((select id from public.guest_requests where status='completed'), 6)$$, '23514', null, 'rating must be 1-5');
select lives_ok($$select public.record_guest_request_feedback((select id from public.guest_requests where status='completed'), 5, 'Quick!')$$, 'feedback recorded');
select lives_ok($$select public.create_guest_request('73000000-0000-0000-0000-000000000001', (select id from public.reservations where channel_ref='G1'), '77000000-0000-0000-0000-000000000002')$$, 'request without routing rule');
select lives_ok($$select public.complete_guest_request((select id from public.guest_requests where title='Late checkout'))$$, 'complete a request that has no task');
select lives_ok($$select public.create_guest_request('73000000-0000-0000-0000-000000000001', (select id from public.reservations where channel_ref='G1'), '77000000-0000-0000-0000-000000000001')$$, 'second routed request');
select throws_ok($$select public.complete_guest_request((select id from public.guest_requests where status='new'))$$, '22023', null, 'cannot bypass the linked task');
select lives_ok($$select public.cancel_guest_request((select id from public.guest_requests where status='new'), 'guest left')$$, 'cancel request');

select set_config('request.jwt.claims', '{"sub":"71000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is((select count(*)::int from public.tasks where guest_request_id is not null and status='cancelled'), 1, 'cancelling a request cancels its open task');

select * from finish();
rollback;
