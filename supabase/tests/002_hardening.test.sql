begin;
select plan(3);

insert into auth.users (id, email) values ('d0000000-0000-0000-0000-00000000000d', 'dave@c.test');
insert into public.tenants (id, name, slug) values ('33333333-3333-3333-3333-333333333333', 'Tenant C', 'tenant-c');
insert into public.tenant_memberships (tenant_id, user_id, role)
  values ('33333333-3333-3333-3333-333333333333', 'd0000000-0000-0000-0000-00000000000d', 'owner');

select throws_ok(
  $$insert into public.properties (tenant_id, name, property_type, timezone)
    values ('33333333-3333-3333-3333-333333333333', 'Bad TZ', 'hotel', 'Mars/Olympus')$$,
  '22023', null, 'invalid timezone rejected');
select throws_ok(
  $$delete from public.tenant_memberships where user_id = 'd0000000-0000-0000-0000-00000000000d'$$,
  '23514', null, 'last owner cannot be removed');
select lives_ok(
  $$delete from public.tenants where id = '33333333-3333-3333-3333-333333333333'$$,
  'tenant deletion still cascades');

select * from finish();
rollback;
