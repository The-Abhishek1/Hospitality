begin;
select plan(23);

insert into auth.users (id, email) values
  ('61000000-0000-0000-0000-000000000001', 'owner@t5.test'), ('61000000-0000-0000-0000-000000000002', 'clerk@t5.test'),
  ('61000000-0000-0000-0000-000000000003', 'hk1@t5.test'),   ('61000000-0000-0000-0000-000000000004', 'hk2@t5.test'),
  ('61000000-0000-0000-0000-000000000005', 'nomember@t5.test');
insert into public.tenants (id, name, slug) values ('62000000-0000-0000-0000-000000000001', 'Tenant 5', 'tenant-5');
insert into public.properties (id, tenant_id, name, property_type) values
  ('63000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000001', 'Prop 5', 'hotel');
insert into public.tenant_memberships (tenant_id, user_id, role)
select '62000000-0000-0000-0000-000000000001', u, case when u = '61000000-0000-0000-0000-000000000001' then 'owner' else 'member' end
from (values ('61000000-0000-0000-0000-000000000001'::uuid), ('61000000-0000-0000-0000-000000000002'), ('61000000-0000-0000-0000-000000000003'),
             ('61000000-0000-0000-0000-000000000004'), ('61000000-0000-0000-0000-000000000005')) v(u);
insert into public.property_memberships (property_id, tenant_id, user_id)
select '63000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000001', u
from (values ('61000000-0000-0000-0000-000000000002'::uuid), ('61000000-0000-0000-0000-000000000003'), ('61000000-0000-0000-0000-000000000004')) v(u);
insert into public.user_roles (property_id, user_id, role_id)
select '63000000-0000-0000-0000-000000000001', v.u, r.id
from (values ('61000000-0000-0000-0000-000000000002'::uuid, 'front_desk'), ('61000000-0000-0000-0000-000000000003', 'housekeeping'),
             ('61000000-0000-0000-0000-000000000004', 'housekeeping')) v(u, k)
join public.roles r on r.key = v.k and r.tenant_id is null;
insert into public.accommodation_types (id, tenant_id, property_id, name, max_occupancy, base_rate) values
  ('64000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000001', '63000000-0000-0000-0000-000000000001', 'Std', 2, 100);
insert into public.accommodation_units (id, tenant_id, property_id, type_id, name) values
  ('66000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000001', '63000000-0000-0000-0000-000000000001', '64000000-0000-0000-0000-000000000001', 'U1');
insert into public.guests (id, tenant_id, full_name) values ('65000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000001', 'Guest');

-- one open housekeeping task per unit (superuser)
select lives_ok($$insert into public.tasks (tenant_id, property_id, title, kind, unit_id) values
  ('62000000-0000-0000-0000-000000000001','63000000-0000-0000-0000-000000000001','dup A','housekeeping','66000000-0000-0000-0000-000000000001')$$, 'first housekeeping task');
select throws_ok($$insert into public.tasks (tenant_id, property_id, title, kind, unit_id) values
  ('62000000-0000-0000-0000-000000000001','63000000-0000-0000-0000-000000000001','dup B','housekeeping','66000000-0000-0000-0000-000000000001')$$, '23505', null, 'duplicate open housekeeping task rejected');
delete from public.tasks;

-- clerk: book, check in, check out
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"61000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select lives_ok($$select public.create_reservation('63000000-0000-0000-0000-000000000001','65000000-0000-0000-0000-000000000001','64000000-0000-0000-0000-000000000001','2027-08-01','2027-08-02',1,0,null,'direct','T1')$$, 'book');
select lives_ok($$select public.check_in_reservation((select id from public.reservations where channel_ref='T1'))$$, 'check in');
select lives_ok($$select public.collect_folio_payment(public.post_room_charges((select id from public.reservations where channel_ref='T1')), 100, 'cash')$$, 'settle folio');
select lives_ok($$select public.check_out_reservation((select id from public.reservations where channel_ref='T1'))$$, 'check out');
select is((select count(*)::int from public.tasks where kind='housekeeping' and status='open'), 0, 'read-only front desk cannot browse unassigned tasks');
select is((select housekeeping_status from public.accommodation_units where name='U1'), 'dirty', 'unit dirty after checkout');

-- hk1 sees and claims it
select set_config('request.jwt.claims', '{"sub":"61000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select is((select count(*)::int from public.tasks), 1, 'housekeeper sees unassigned task');
select lives_ok($$select public.claim_task((select id from public.tasks where kind='housekeeping'))$$, 'hk1 claims');

-- hk2 is shut out
select set_config('request.jwt.claims', '{"sub":"61000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
select is_empty($$select 1 from public.tasks$$, 'other housekeeper cannot see claimed task');
select throws_ok($$select public.set_task_status((select id from public.tasks limit 1), 'done')$$, '42501', null, 'cannot update a task you cannot see');

-- hk1 works it
select set_config('request.jwt.claims', '{"sub":"61000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select lives_ok($$select public.set_task_status((select id from public.tasks where kind='housekeeping'), 'in_progress')$$, 'start');
select is((select housekeeping_status from public.accommodation_units where name='U1'), 'in_progress', 'unit in progress');
select lives_ok($$select public.set_task_status((select id from public.tasks where kind='housekeeping'), 'done')$$, 'finish');
select is((select housekeeping_status from public.accommodation_units where name='U1'), 'clean', 'unit clean again');
select throws_ok($$select public.create_task('63000000-0000-0000-0000-000000000001','Sneaky')$$, '42501', null, 'housekeeper cannot create tasks');
select lives_ok($$insert into public.task_comments (tenant_id, property_id, task_id, author_id, body)
  select tenant_id, property_id, id, '61000000-0000-0000-0000-000000000003', 'Minibar restocked' from public.tasks$$, 'assignee comments');

select set_config('request.jwt.claims', '{"sub":"61000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
select is_empty($$select 1 from public.task_comments$$, 'comments follow task visibility');

-- owner (tenant admin)
select set_config('request.jwt.claims', '{"sub":"61000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$select public.create_task('63000000-0000-0000-0000-000000000001','Fix tap','maintenance','high','61000000-0000-0000-0000-000000000004')$$, 'owner creates and assigns');
select throws_ok($$select public.assign_task((select id from public.tasks where title='Fix tap'),'61000000-0000-0000-0000-000000000005')$$, '23503', null, 'assignee must be a property member');

select set_config('request.jwt.claims', '{"sub":"61000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select throws_ok($$select public.assign_task((select id from public.tasks limit 1),'61000000-0000-0000-0000-000000000003')$$, '42501', null, 'front desk cannot assign tasks');

select set_config('request.jwt.claims', '{"sub":"61000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is((select count(*)::int from public.task_events e join public.tasks t on t.id = e.task_id where t.kind = 'housekeeping'), 4, 'housekeeping task has a full audit trail');

select * from finish();
rollback;
