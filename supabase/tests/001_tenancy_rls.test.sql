begin;
select plan(13);

-- fixtures (as superuser)
insert into auth.users (id, email) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@a.test'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@a.test'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@b.test');

insert into public.tenants (id, name, slug) values
  ('11111111-1111-1111-1111-111111111111', 'Tenant A', 'tenant-a'),
  ('22222222-2222-2222-2222-222222222222', 'Tenant B', 'tenant-b');
insert into public.properties (id, tenant_id, name, property_type) values
  ('aaaaaaa1-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'A Hotel 1', 'hotel'),
  ('aaaaaaa2-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'A Hotel 2', 'hostel'),
  ('bbbbbbb1-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'B Resort', 'resort');
insert into public.tenant_memberships (tenant_id, user_id, role) values
  ('11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-00000000000a', 'owner'),
  ('11111111-1111-1111-1111-111111111111', 'b0000000-0000-0000-0000-00000000000b', 'member'),
  ('22222222-2222-2222-2222-222222222222', 'c0000000-0000-0000-0000-00000000000c', 'owner');
insert into public.property_memberships (property_id, tenant_id, user_id) values
  ('aaaaaaa1-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'b0000000-0000-0000-0000-00000000000b');
insert into public.user_roles (property_id, user_id, role_id)
select 'aaaaaaa1-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-00000000000b', id
from public.roles where key = 'front_desk' and tenant_id is null;

-- structural: composite FK blocks cross-tenant membership
select throws_ok(
  $$insert into public.property_memberships (property_id, tenant_id, user_id) values
    ('aaaaaaa1-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','c0000000-0000-0000-0000-00000000000c')$$,
  '23503', null, 'cross-tenant property membership is rejected');

-- alice: owner of tenant A
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
select is((select count(*)::int from public.tenants), 1, 'owner sees only own tenant');
select is((select count(*)::int from public.properties), 2, 'owner sees all properties of own tenant');
select ok(private.has_permission('aaaaaaa2-0000-0000-0000-000000000002', 'finance.write'), 'owner has implicit permissions');

-- bob: member with front_desk role on property 1 only
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);
select is((select count(*)::int from public.properties), 1, 'member sees only assigned property');
select ok(private.has_permission('aaaaaaa1-0000-0000-0000-000000000001', 'reservations.write'), 'role grants permission');
select ok(not private.has_permission('aaaaaaa1-0000-0000-0000-000000000001', 'finance.write'), 'role does not grant other permissions');
select throws_ok(
  $$insert into public.properties (tenant_id, name, property_type) values ('11111111-1111-1111-1111-111111111111','x1','hotel')$$,
  '42501', null, 'member cannot create properties');

-- carol: other tenant
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-00000000000c","role":"authenticated"}', true);
select is_empty($$select 1 from public.tenants where id = '11111111-1111-1111-1111-111111111111'$$, 'cannot see another tenant');
select isnt(public.create_tenant('Carol Two', 'carol-two'), null, 'authenticated user can create tenant');
select lives_ok(
  $$insert into public.properties (tenant_id, name, property_type)
    values ('22222222-2222-2222-2222-222222222222', 'New B Hotel', 'hotel') returning id$$,
  'owner can create a property and return its id');
select throws_ok(
  $$insert into public.properties (tenant_id, name, property_type)
    values ('11111111-1111-1111-1111-111111111111', 'Unauthorized Hotel', 'hotel') returning id$$,
  '42501', null, 'owner cannot create a property in another tenant');

-- anon
reset role;
set local role anon;
select throws_ok($$select public.create_tenant('Nope Inc', 'nope-inc')$$, '42501', null, 'anon cannot create tenant');

select * from finish();
rollback;
