begin;
select plan(28);

insert into auth.users (id, email) values
  ('81000000-0000-0000-0000-000000000001', 'owner@t7.test'), ('81000000-0000-0000-0000-000000000002', 'clerk@t7.test'),
  ('81000000-0000-0000-0000-000000000003', 'cook@t7.test'),  ('81000000-0000-0000-0000-000000000004', 'acct@t7.test'),
  ('81000000-0000-0000-0000-000000000005', 'hk@t7.test');
insert into public.tenants (id, name, slug) values ('82000000-0000-0000-0000-000000000001', 'Tenant 7', 'tenant-7');
insert into public.properties (id, tenant_id, name, property_type) values
  ('83000000-0000-0000-0000-000000000001', '82000000-0000-0000-0000-000000000001', 'Prop 7', 'hotel');
insert into public.tenant_memberships (tenant_id, user_id, role)
select '82000000-0000-0000-0000-000000000001', u, case when u = '81000000-0000-0000-0000-000000000001' then 'owner' else 'member' end
from (values ('81000000-0000-0000-0000-000000000001'::uuid), ('81000000-0000-0000-0000-000000000002'), ('81000000-0000-0000-0000-000000000003'),
             ('81000000-0000-0000-0000-000000000004'), ('81000000-0000-0000-0000-000000000005')) v(u);
insert into public.property_memberships (property_id, tenant_id, user_id)
select '83000000-0000-0000-0000-000000000001', '82000000-0000-0000-0000-000000000001', u
from (values ('81000000-0000-0000-0000-000000000002'::uuid), ('81000000-0000-0000-0000-000000000003'),
             ('81000000-0000-0000-0000-000000000004'), ('81000000-0000-0000-0000-000000000005')) v(u);
insert into public.user_roles (property_id, user_id, role_id)
select '83000000-0000-0000-0000-000000000001', v.u, r.id
from (values ('81000000-0000-0000-0000-000000000002'::uuid, 'front_desk'), ('81000000-0000-0000-0000-000000000003', 'kitchen'),
             ('81000000-0000-0000-0000-000000000004', 'accountant'), ('81000000-0000-0000-0000-000000000005', 'housekeeping')) v(u, k)
join public.roles r on r.key = v.k and r.tenant_id is null;
insert into public.accommodation_types (id, tenant_id, property_id, name, max_occupancy, base_rate) values
  ('84000000-0000-0000-0000-000000000001', '82000000-0000-0000-0000-000000000001', '83000000-0000-0000-0000-000000000001', 'Std', 2, 100);
insert into public.accommodation_units (tenant_id, property_id, type_id, name) values
  ('82000000-0000-0000-0000-000000000001', '83000000-0000-0000-0000-000000000001', '84000000-0000-0000-0000-000000000001', 'U1');
insert into public.guests (id, tenant_id, full_name) values ('85000000-0000-0000-0000-000000000001', '82000000-0000-0000-0000-000000000001', 'Guest');
insert into public.menu_categories (id, tenant_id, property_id, name) values
  ('86000000-0000-0000-0000-000000000001', '82000000-0000-0000-0000-000000000001', '83000000-0000-0000-0000-000000000001', 'Mains');
insert into public.menu_items (id, tenant_id, property_id, category_id, name, price, tax_rate_percent) values
  ('87000000-0000-0000-0000-000000000001', '82000000-0000-0000-0000-000000000001', '83000000-0000-0000-0000-000000000001', '86000000-0000-0000-0000-000000000001', 'Tea', 50, 10),
  ('87000000-0000-0000-0000-000000000002', '82000000-0000-0000-0000-000000000001', '83000000-0000-0000-0000-000000000001', '86000000-0000-0000-0000-000000000001', 'Soup', 150, 0);

-- owner books a past 2-night stay (total 200) and checks the guest in
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
do $$ begin
  perform public.create_reservation('83000000-0000-0000-0000-000000000001','85000000-0000-0000-0000-000000000001','84000000-0000-0000-0000-000000000001','2026-01-10','2026-01-12',1,0,null,'direct','B1');
  perform public.check_in_reservation((select id from public.reservations where channel_ref='B1'));
end $$;

-- front desk places a room-service order: 2 tea (+10% tax) + 1 soup = 260
select set_config('request.jwt.claims', '{"sub":"81000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select lives_ok($$select public.place_order('83000000-0000-0000-0000-000000000001','room_service',
  '[{"menu_item_id":"87000000-0000-0000-0000-000000000001","quantity":2},{"menu_item_id":"87000000-0000-0000-0000-000000000002","quantity":1}]'::jsonb,
  (select id from public.reservations where channel_ref='B1'))$$, 'place room-service order');
select is((select total from public.orders where kind='room_service'), 260.00, 'order total includes tax');
select throws_ok($$select public.place_order('83000000-0000-0000-0000-000000000001','restaurant','[{"menu_item_id":"87000000-0000-0000-0000-0000000000ff","quantity":1}]'::jsonb)$$, '22023', null, 'unknown menu item rejected');
select throws_ok($$select public.post_folio_charge((select id from public.reservations where channel_ref='B1'), 'Discount', -10)$$, '42501', null, 'front desk cannot post credits');

-- housekeeper has no order or billing access
select set_config('request.jwt.claims', '{"sub":"81000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
select throws_ok($$select public.place_order('83000000-0000-0000-0000-000000000001','restaurant','[{"menu_item_id":"87000000-0000-0000-0000-000000000002","quantity":1}]'::jsonb)$$, '42501', null, 'housekeeper cannot place orders');
select is_empty($$select 1 from public.orders$$, 'housekeeper sees no orders');

-- kitchen works the order; serving charges it to the room folio
select set_config('request.jwt.claims', '{"sub":"81000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select is((select count(*)::int from public.orders), 1, 'kitchen sees the order');
select throws_ok($$select public.set_order_status((select id from public.orders where kind='room_service'), 'ready')$$, '22023', null, 'cannot skip preparing');
select lives_ok($$select public.set_order_status((select id from public.orders where kind='room_service'), 'preparing')$$, 'preparing');
do $$ begin perform public.set_order_status((select id from public.orders where kind='room_service'), 'ready'); end $$;
select lives_ok($$select public.set_order_status((select id from public.orders where kind='room_service'), 'served')$$, 'served');
select is_empty($$select 1 from public.folios$$, 'kitchen cannot see folios');

-- front desk: folio, night audit, settlement
select set_config('request.jwt.claims', '{"sub":"81000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select is((select amount from public.folio_items where kind='order'), 260.00, 'served order charged to folio');
select lives_ok($$select public.run_night_audit('83000000-0000-0000-0000-000000000001','2026-01-10')$$, 'night audit posts first night');
select lives_ok($$select public.run_night_audit('83000000-0000-0000-0000-000000000001','2026-01-10')$$, 'night audit is re-runnable');
select is((select count(*)::int from public.folio_items where kind='room'), 1, 'room night posted exactly once');
select throws_ok($$select public.run_night_audit('83000000-0000-0000-0000-000000000001','2999-01-01')$$, '22023', null, 'future business date rejected');
select is(public.folio_balance((select id from public.folios limit 1)), 360.00, 'balance = 1 night + order');
select throws_ok($$select public.finalize_invoice((select id from public.folios limit 1))$$, '22023', null, 'cannot invoice with a balance');
select lives_ok($$select public.collect_folio_payment((select id from public.folios limit 1), 360, 'cash')$$, 'collect payment');
select throws_ok($$select public.check_out_reservation((select id from public.reservations where channel_ref='B1'))$$, '22023', null, 'checkout blocked: second night still owed');
select lives_ok($$select public.collect_folio_payment(public.post_room_charges((select id from public.reservations where channel_ref='B1')), 100, 'upi', 'ref-1')$$, 'post remaining night and pay');
select lives_ok($$select public.check_out_reservation((select id from public.reservations where channel_ref='B1'))$$, 'checkout succeeds when settled');
select lives_ok($$select public.finalize_invoice((select id from public.folios limit 1))$$, 'invoice issued');
select ok((select number from public.invoices) ~ '^INV-[0-9]{4}-[0-9]{6}$', 'invoice number format');
select throws_ok($$select public.post_folio_charge((select id from public.reservations where channel_ref='B1'), 'Late fee', 10)$$, '22023', null, 'closed folio rejects charges');

-- refunds need finance.write
select throws_ok($$select public.refund_payment((select id from public.payments where method='upi'), 50, 'goodwill')$$, '42501', null, 'front desk cannot refund');
select set_config('request.jwt.claims', '{"sub":"81000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
select lives_ok($$select public.refund_payment((select id from public.payments where method='upi'), 50, 'goodwill')$$, 'accountant refunds');
select throws_ok($$select public.refund_payment((select id from public.payments where method='upi'), 1000, 'too much')$$, '22023', null, 'refund cannot exceed payment');

select * from finish();
rollback;
