begin;
select plan(29);

insert into auth.users (id, email, email_confirmed_at) values
  ('b1000000-0000-0000-0000-000000000001', 'owner@t10.test', now()), ('b1000000-0000-0000-0000-000000000002', 'admin@t10.test', now()),
  ('b1000000-0000-0000-0000-000000000003', 'member@t10.test', now()), ('b1000000-0000-0000-0000-000000000004', 'new@x.com', now()),
  ('b1000000-0000-0000-0000-000000000005', 'other@x.com', now()), ('b1000000-0000-0000-0000-000000000006', 'unconf@x.com', null),
  ('b1000000-0000-0000-0000-000000000007', 'exp@x.com', now()), ('b1000000-0000-0000-0000-000000000008', 'rev@x.com', now());
insert into public.tenants (id, name, slug) values
  ('b2000000-0000-0000-0000-000000000001', 'Tenant 10', 'tenant-10'), ('b2000000-0000-0000-0000-000000000002', 'Other Tenant', 'other-tenant');
insert into public.properties (id, tenant_id, name, property_type) values
  ('b3000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000001', 'Prop 10', 'hotel'),
  ('b3000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000002', 'Foreign Prop', 'hotel');
insert into public.tenant_memberships (tenant_id, user_id, role) values
  ('b2000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'owner'),
  ('b2000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000002', 'admin'),
  ('b2000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000003', 'member');
insert into public.staff_invitations (tenant_id, email, tenant_role, expires_at) values
  ('b2000000-0000-0000-0000-000000000001', 'unconf@x.com', 'member', now() + interval '1 day'),
  ('b2000000-0000-0000-0000-000000000001', 'exp@x.com', 'member', now() - interval '1 day');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$select public.invite_staff('b2000000-0000-0000-0000-000000000001', 'New@X.com ', 'member', '[{"property_id":"b3000000-0000-0000-0000-000000000001","role_key":"front_desk"}]'::jsonb)$$, 'owner invites (email normalised)');
select throws_ok($$select public.invite_staff('b2000000-0000-0000-0000-000000000001', 'new@x.com', 'member')$$, '23505', null, 'one pending invitation per email');
select throws_ok($$select public.invite_staff('b2000000-0000-0000-0000-000000000001', 'a@b.com', 'member', '[{"property_id":"b3000000-0000-0000-0000-000000000002","role_key":"front_desk"}]'::jsonb)$$, '22023', null, 'cannot grant access to another tenant''s property');
select throws_ok($$select public.invite_staff('b2000000-0000-0000-0000-000000000001', 'a@b.com', 'member', '[{"property_id":"b3000000-0000-0000-0000-000000000001","role_key":"wizard"}]'::jsonb)$$, '22023', null, 'unknown role rejected');
select throws_ok($$select public.invite_staff('b2000000-0000-0000-0000-000000000001', 'a@b.com', 'owner')$$, '22023', null, 'owners cannot be created by invitation');
do $$ begin perform public.invite_staff('b2000000-0000-0000-0000-000000000001', 'rev@x.com', 'member'); end $$;
select lives_ok($$select public.revoke_staff_invitation((select id from public.staff_invitations where email = 'rev@x.com'))$$, 'owner revokes an invitation');

select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select throws_ok($$select public.invite_staff('b2000000-0000-0000-0000-000000000001', 'x@y.com', 'member')$$, '42501', null, 'plain member cannot invite');

-- acceptance rules
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
select is(public.accept_staff_invitations(), 0, 'a different email cannot claim the invitation');
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-000000000006","role":"authenticated"}', true);
select is(public.accept_staff_invitations(), 0, 'unconfirmed email cannot claim');
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-000000000007","role":"authenticated"}', true);
select is(public.accept_staff_invitations(), 0, 'expired invitation ignored');
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-000000000008","role":"authenticated"}', true);
select is(public.accept_staff_invitations(), 0, 'revoked invitation ignored');
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
select is(public.accept_staff_invitations(), 1, 'invited, confirmed user accepts');
select is((select count(*)::int from public.tenants), 1, 'invitee can now see the tenant');
select ok(private.has_permission('b3000000-0000-0000-0000-000000000001', 'reservations.write'), 'invited role grants permissions');
select is(public.accept_staff_invitations(), 0, 'accepting twice does nothing');

-- role assignment
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is((select email from public.profiles where id = 'b1000000-0000-0000-0000-000000000004'), 'new@x.com', 'colleagues see each other''s email');
select lives_ok($$select public.set_staff_access('b3000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000004', array['housekeeping'])$$, 'owner replaces roles');
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
select ok(private.has_permission('b3000000-0000-0000-0000-000000000001', 'tasks.write'), 'new role applies');
select ok(not private.has_permission('b3000000-0000-0000-0000-000000000001', 'reservations.write'), 'old role removed');
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select throws_ok($$select public.set_staff_access('b3000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000004', array['manager'])$$, '42501', null, 'member cannot assign roles');
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$select public.set_staff_access('b3000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000004', array['wizard'])$$, '22023', null, 'unknown role key rejected');
select throws_ok($$select public.set_staff_access('b3000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000002', array['manager'])$$, '22023', null, 'admins already have full access');
select lives_ok($$select public.set_staff_access('b3000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000004', '{}')$$, 'empty list removes property access');
select is((select count(*)::int from public.property_memberships where user_id = 'b1000000-0000-0000-0000-000000000004'), 0, 'property access gone');

-- removal and ownership
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select throws_ok($$select public.remove_staff('b2000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001')$$, '42501', null, 'admin cannot remove an owner');
select throws_ok($$select public.set_tenant_role('b2000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000003', 'admin')$$, '42501', null, 'admin cannot change tenant roles');
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$select public.remove_staff('b2000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000004')$$, 'owner removes a member');
select throws_ok($$select public.remove_staff('b2000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001')$$, '23514', null, 'the last owner cannot be removed');
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
select is_empty($$select 1 from public.tenants$$, 'removed user loses all access');

select * from finish();
rollback;
