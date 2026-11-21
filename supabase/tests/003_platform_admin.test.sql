begin;
select plan(11);

insert into auth.users (id, email) values
  ('e0000000-0000-0000-0000-00000000000e', 'root@platform.test'),
  ('f0000000-0000-0000-0000-00000000000f', 'owner@t.test'),
  ('90000000-0000-0000-0000-000000000009', 'outsider@x.test');
insert into public.platform_admins (user_id) values ('e0000000-0000-0000-0000-00000000000e');
insert into public.tenants (id, name, slug) values ('44444444-4444-4444-4444-444444444444', 'Tenant T', 'tenant-t');
insert into public.tenant_memberships (tenant_id, user_id, role)
  values ('44444444-4444-4444-4444-444444444444', 'f0000000-0000-0000-0000-00000000000f', 'owner');
insert into public.subscriptions (tenant_id, plan_id, status)
  select '44444444-4444-4444-4444-444444444444', id, 'active' from public.plans where key = 'starter';

-- entitlement: starter allows 2 properties
select lives_ok($$insert into public.properties (tenant_id, name, property_type) values ('44444444-4444-4444-4444-444444444444','P One','hotel')$$, 'property 1 within limit');
select lives_ok($$insert into public.properties (tenant_id, name, property_type) values ('44444444-4444-4444-4444-444444444444','P Two','hotel')$$, 'property 2 within limit');
select throws_ok($$insert into public.properties (tenant_id, name, property_type) values ('44444444-4444-4444-4444-444444444444','P Three','hotel')$$, '53400', null, 'property 3 exceeds starter limit');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"90000000-0000-0000-0000-000000000009","role":"authenticated"}', true);
select is_empty($$select 1 from public.subscriptions$$, 'outsider sees no subscriptions');

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-00000000000f","role":"authenticated"}', true);
select is((select count(*)::int from public.subscriptions), 1, 'owner sees own subscription');
select throws_ok($$select public.admin_assign_plan('44444444-4444-4444-4444-444444444444','growth')$$, '42501', null, 'owner cannot assign plans');
select throws_ok($$insert into public.platform_audit_logs (action) values ('forged')$$, '42501', null, 'clients cannot write audit logs');

select set_config('request.jwt.claims', '{"sub":"e0000000-0000-0000-0000-00000000000e","role":"authenticated"}', true);
select is((select count(*)::int from public.tenants where id='44444444-4444-4444-4444-444444444444'), 1, 'platform admin sees the fixture tenant');
select lives_ok($$select public.admin_assign_plan('44444444-4444-4444-4444-444444444444','growth')$$, 'platform admin assigns plan');
select is((select count(*)::int from public.platform_audit_logs where action = 'platform_plan' and tenant_id='44444444-4444-4444-4444-444444444444'), 1, 'assignment is audited');

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-00000000000f","role":"authenticated"}', true);
select lives_ok($$select public.create_tenant('Zed Co','zed-co')$$, 'owner creates second tenant');

select * from finish();
rollback;
