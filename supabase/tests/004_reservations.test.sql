begin;
select plan(22);

-- fixtures
insert into auth.users (id, email) values
  ('10000000-0000-0000-0000-000000000001', 'owner@p.test'),
  ('10000000-0000-0000-0000-000000000002', 'clerk@p.test'),
  ('10000000-0000-0000-0000-000000000003', 'nobody@p.test');
insert into public.tenants (id, name, slug) values
  ('51000000-0000-0000-0000-000000000001', 'Tenant P', 'tenant-p'),
  ('51000000-0000-0000-0000-000000000002', 'Tenant Q', 'tenant-q');
insert into public.properties (id, tenant_id, name, property_type) values
  ('52000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'Prop P', 'hotel');
insert into public.tenant_memberships (tenant_id, user_id, role) values
  ('51000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'owner'),
  ('51000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', 'member'),
  ('51000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000003', 'member');
insert into public.property_memberships (property_id, tenant_id, user_id)
select '52000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', u
from (values ('10000000-0000-0000-0000-000000000002'::uuid), ('10000000-0000-0000-0000-000000000003'::uuid)) v(u);
insert into public.user_roles (property_id, user_id, role_id)
select '52000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', id
from public.roles where key = 'front_desk' and tenant_id is null;
insert into public.accommodation_types (id, tenant_id, property_id, name, max_occupancy, base_rate) values
  ('53000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', '52000000-0000-0000-0000-000000000001', 'Deluxe', 2, 1000);
insert into public.accommodation_units (tenant_id, property_id, type_id, name) values
  ('51000000-0000-0000-0000-000000000001', '52000000-0000-0000-0000-000000000001', '53000000-0000-0000-0000-000000000001', 'D1'),
  ('51000000-0000-0000-0000-000000000001', '52000000-0000-0000-0000-000000000001', '53000000-0000-0000-0000-000000000001', 'D2');
insert into public.guests (id, tenant_id, full_name) values
  ('54000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'Guest G'),
  ('54000000-0000-0000-0000-000000000002', '51000000-0000-0000-0000-000000000002', 'Guest H (other tenant)');

-- 1-2: the exclusion constraint itself (superuser, bypasses RLS and functions)
select lives_ok($$insert into public.unit_holds (tenant_id, property_id, unit_id, during, kind)
  select tenant_id, property_id, id, '[2027-01-10,2027-01-15)', 'block' from public.accommodation_units where name = 'D1'$$, 'block inserted');
select throws_ok($$insert into public.unit_holds (tenant_id, property_id, unit_id, during, kind)
  select tenant_id, property_id, id, '[2027-01-12,2027-01-14)', 'block' from public.accommodation_units where name = 'D1'$$,
  '23P01', null, 'overlapping hold rejected by constraint');

-- clerk (front_desk)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}', true);

select lives_ok($$select public.create_reservation('52000000-0000-0000-0000-000000000001','54000000-0000-0000-0000-000000000001','53000000-0000-0000-0000-000000000001','2027-03-10','2027-03-12',2,0,null,'direct','R1')$$, 'R1 books unit 1');
select lives_ok($$select public.create_reservation('52000000-0000-0000-0000-000000000001','54000000-0000-0000-0000-000000000001','53000000-0000-0000-0000-000000000001','2027-03-10','2027-03-12',2,0,null,'direct','R2')$$, 'R2 books unit 2');
select throws_ok($$select public.create_reservation('52000000-0000-0000-0000-000000000001','54000000-0000-0000-0000-000000000001','53000000-0000-0000-0000-000000000001','2027-03-10','2027-03-12',1,0,null,'direct','R3')$$, 'P0002', null, 'third booking: no availability');
select lives_ok($$select public.create_reservation('52000000-0000-0000-0000-000000000001','54000000-0000-0000-0000-000000000001','53000000-0000-0000-0000-000000000001','2027-03-12','2027-03-14',1,0,null,'direct','R-b2b')$$, 'same-day turnover allowed');
select is(
  public.create_reservation('52000000-0000-0000-0000-000000000001','54000000-0000-0000-0000-000000000001','53000000-0000-0000-0000-000000000001','2027-04-01','2027-04-03',1,0,null,'ota','OTA-1'),
  public.create_reservation('52000000-0000-0000-0000-000000000001','54000000-0000-0000-0000-000000000001','53000000-0000-0000-0000-000000000001','2027-04-01','2027-04-03',1,0,null,'ota','OTA-1'),
  'retry with same channel_ref is idempotent');
select throws_ok($$select public.create_reservation('52000000-0000-0000-0000-000000000001','54000000-0000-0000-0000-000000000002','53000000-0000-0000-0000-000000000001','2027-05-01','2027-05-02')$$, '23503', null, 'guest from another tenant rejected');
select throws_ok($$select public.create_reservation('52000000-0000-0000-0000-000000000001','54000000-0000-0000-0000-000000000001','53000000-0000-0000-0000-000000000001','2027-05-01','2027-05-02',3,0)$$, '22023', null, 'over-occupancy rejected');
select throws_ok($$select public.create_inventory_block((select id from public.accommodation_units where name='D1'),'2027-06-01','2027-06-03')$$, '42501', null, 'clerk lacks inventory.manage');

select lives_ok($$select public.cancel_reservation((select id from public.reservations where channel_ref='R1'), 'test')$$, 'cancel R1');
select lives_ok($$select public.create_reservation('52000000-0000-0000-0000-000000000001','54000000-0000-0000-0000-000000000001','53000000-0000-0000-0000-000000000001','2027-03-10','2027-03-12',1,0,null,'direct','R4')$$, 'cancelled nights are rebookable');

select lives_ok($$select public.check_in_reservation((select id from public.reservations where channel_ref='R2'))$$, 'check in R2');
select is((select status from public.reservations where channel_ref='R2'), 'checked_in', 'R2 is checked_in');
select lives_ok($$select public.collect_folio_payment(public.post_room_charges((select id from public.reservations where channel_ref='R2')), 2000, 'cash')$$, 'settle R2 folio');
select lives_ok($$select public.check_out_reservation((select id from public.reservations where channel_ref='R2'))$$, 'check out R2');
select is((select housekeeping_status from public.accommodation_units where name='D2'), 'dirty', 'unit marked dirty after checkout');
select throws_ok($$select public.check_in_reservation((select id from public.reservations where channel_ref='R1'))$$, '22023', null, 'cannot check in a cancelled reservation');

-- nobody: member without a role
select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select throws_ok($$select public.create_reservation('52000000-0000-0000-0000-000000000001','54000000-0000-0000-0000-000000000001','53000000-0000-0000-0000-000000000001','2027-07-01','2027-07-02')$$, '42501', null, 'no permission, no booking');
select is_empty($$select 1 from public.reservations$$, 'no reservations.read, no rows');

-- owner
select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$select public.create_inventory_block((select id from public.accommodation_units where name='D1'),'2027-03-11','2027-03-13')$$, '23P01', null, 'cannot block a booked unit');
select is((select available from public.availability('52000000-0000-0000-0000-000000000001','2027-05-01','2027-05-03')), 2::bigint, 'availability counts free units');

select * from finish();
rollback;
