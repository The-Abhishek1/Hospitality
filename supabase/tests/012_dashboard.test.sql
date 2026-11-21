begin;
select plan(20);
insert into auth.users(id,email) values
('d1000000-0000-0000-0000-000000000001','owner@dashboard.test'),
('d1000000-0000-0000-0000-000000000002','member@dashboard.test');
insert into public.tenants(id,name,slug) values ('d2000000-0000-0000-0000-000000000001','Dashboard tenant','dashboard-test');
insert into public.properties(id,tenant_id,name,property_type,timezone) values
('d3000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000001','Dashboard hotel','hotel','Asia/Kolkata'),
('d3000000-0000-0000-0000-000000000002','d2000000-0000-0000-0000-000000000001','Other hotel','hotel','UTC');
insert into public.tenant_memberships(tenant_id,user_id,role) values
('d2000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000001','owner'),
('d2000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000002','member');
insert into public.property_memberships(tenant_id,property_id,user_id) values
('d2000000-0000-0000-0000-000000000001','d3000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000002');
insert into public.accommodation_types(id,tenant_id,property_id,name,max_occupancy,base_rate) values
('d4000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000001','d3000000-0000-0000-0000-000000000001','Standard',2,100);
insert into public.accommodation_units(tenant_id,property_id,type_id,name,housekeeping_status) values
('d2000000-0000-0000-0000-000000000001','d3000000-0000-0000-0000-000000000001','d4000000-0000-0000-0000-000000000001','101','clean'),
('d2000000-0000-0000-0000-000000000001','d3000000-0000-0000-0000-000000000001','d4000000-0000-0000-0000-000000000001','102','dirty');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is((public.dashboard_snapshot('d3000000-0000-0000-0000-000000000001')->>'units')::int,2,'counts active units');
select is((public.dashboard_snapshot('d3000000-0000-0000-0000-000000000001')#>>'{rooms,dirty}')::int,1,'reports cleaning state');
select is(jsonb_array_length(public.dashboard_snapshot('d3000000-0000-0000-0000-000000000001')->'forecast'),7,'forecast covers seven property-local days');
select is(public.dashboard_snapshot('d3000000-0000-0000-0000-000000000001')->>'day',((now() at time zone 'Asia/Kolkata')::date)::text,'business date uses hotel timezone');
select is((public.dashboard_snapshot('d3000000-0000-0000-0000-000000000001')->>'collections')::numeric,0::numeric,'empty collections are zero');
select is((public.dashboard_snapshot('d3000000-0000-0000-0000-000000000002')->>'units')::int,0,'does not combine properties');
do $$ declare r uuid; f uuid; py uuid; d date := (now() at time zone 'Asia/Kolkata')::date; begin
  insert into public.guests(id,tenant_id,full_name) values ('d5000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000001','Dashboard guest');
  r := public.create_reservation('d3000000-0000-0000-0000-000000000001','d5000000-0000-0000-0000-000000000001','d4000000-0000-0000-0000-000000000001',d,d+1);
  perform public.check_in_reservation(r);
  f := public.post_room_charges(r);
  py := public.collect_folio_payment(f,40,'cash');
  perform public.refund_payment(py,10,'test partial refund');
end $$;
select is((public.dashboard_snapshot('d3000000-0000-0000-0000-000000000001')->>'arrivals')::int,1,'checked-in arrival remains in today total');
select is((public.dashboard_snapshot('d3000000-0000-0000-0000-000000000001')->>'arrivals_pending')::int,0,'checked-in arrival is not pending');
select is((public.dashboard_snapshot('d3000000-0000-0000-0000-000000000001')#>>'{forecast,0,booked}')::int,1,'tonight counts reservation holds');
select is((public.dashboard_snapshot('d3000000-0000-0000-0000-000000000001')#>>'{forecast,1,booked}')::int,0,'checkout night is free');
select is((public.dashboard_snapshot('d3000000-0000-0000-0000-000000000001')->>'collections')::numeric,40::numeric,'collections show gross payments');
select is((public.dashboard_snapshot('d3000000-0000-0000-0000-000000000001')->>'outstanding')::numeric,70::numeric,'outstanding includes charges less payments plus refunds');
select ok((public.workspace_permissions('d3000000-0000-0000-0000-000000000001')->>'finance')::boolean,'owner sees billing navigation');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select ok(not (public.dashboard_snapshot('d3000000-0000-0000-0000-000000000001') ? 'collections'),'member without finance access receives no financial data');
select ok(not (public.dashboard_snapshot('d3000000-0000-0000-0000-000000000001') ? 'stays'),'member without reservation permission receives no guest list');
select throws_ok($$select public.dashboard_snapshot('d3000000-0000-0000-0000-000000000002')$$,'42501',null,'member cannot inspect another property');
select ok(not (public.workspace_permissions('d3000000-0000-0000-0000-000000000001')->>'finance')::boolean,'member without finance permission has no billing navigation');
select throws_ok($$select public.workspace_permissions('d3000000-0000-0000-0000-000000000002')$$,'42501',null,'navigation cannot inspect another hotel');
reset role;
set local role anon;
select throws_ok($$select public.dashboard_snapshot('d3000000-0000-0000-0000-000000000001')$$,'42501',null,'anonymous caller cannot inspect dashboard');
select throws_ok($$select public.workspace_permissions('d3000000-0000-0000-0000-000000000001')$$,'42501',null,'anonymous callers cannot inspect navigation');
select * from finish();
rollback;
