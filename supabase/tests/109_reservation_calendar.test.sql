begin;
select no_plan();
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

insert into public.accommodation_units(tenant_id,property_id,type_id,name,housekeeping_status,active)
select 'd2000000-0000-0000-0000-000000000001','d3000000-0000-0000-0000-000000000001','d4000000-0000-0000-0000-000000000001','P'||lpad(n::text,3,'0'),case when n=12 then'in_progress'when n=13 then'dirty'else'clean'end,n<>13 from generate_series(1,13)n;
insert into public.guests(id,tenant_id,full_name)values('d5000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000001','Calendar guest');
insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)
select('d6000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'d2000000-0000-0000-0000-000000000001','d3000000-0000-0000-0000-000000000001','d5000000-0000-0000-0000-000000000001',case when n=2 then'checked_in'else'confirmed'end,
 (now()at time zone'Asia/Kolkata')::date+case n when 2 then -1 when 3 then 1 else 0 end,
 (now()at time zone'Asia/Kolkata')::date+case n when 2 then 0 else 2 end,100,'INR'from generate_series(1,3)n;
insert into public.unit_holds(tenant_id,property_id,unit_id,reservation_id,kind,during)
select r.tenant_id,r.property_id,u.id,r.id,'reservation',daterange(r.check_in,r.check_out,'[)')from public.reservations r join public.accommodation_units u on u.property_id=r.property_id and u.name=case right(r.id::text,1)when'1'then'102'when'2'then'P001'else'101'end where r.property_id='d3000000-0000-0000-0000-000000000001';
insert into public.unit_holds(tenant_id,property_id,unit_id,kind,during,reason)select u.tenant_id,u.property_id,u.id,'block',daterange((now()at time zone'Asia/Kolkata')::date,(now()at time zone'Asia/Kolkata')::date+1,'[)'),'Synthetic maintenance'from public.accommodation_units u where property_id='d3000000-0000-0000-0000-000000000001'and name='P002';
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is((public.reservation_workspace('d3000000-0000-0000-0000-000000000001')#>>'{room_insights,total}')::int,14,'summary excludes inactive rooms');
select is((public.reservation_workspace('d3000000-0000-0000-0000-000000000001')#>>'{room_insights,booked}')::int,1,'booked counts confirmed rooms for today, not future stays');
select is((public.reservation_workspace('d3000000-0000-0000-0000-000000000001')#>>'{room_insights,in_house}')::int,1,'checkout-day guest remains in house until checkout completes');
select is((public.reservation_workspace('d3000000-0000-0000-0000-000000000001')#>>'{room_insights,blocked}')::int,1,'counts current maintenance blocks');
select is((public.reservation_workspace('d3000000-0000-0000-0000-000000000001')#>>'{room_insights,empty}')::int,11,'empty excludes booked, blocked and still-occupied rooms');
select is((public.reservation_workspace('d3000000-0000-0000-0000-000000000001')#>>'{room_insights,ready}')::int,10,'ready counts only clean empty rooms, excluding in-house and blocked rooms');
select is((public.reservation_workspace('d3000000-0000-0000-0000-000000000001')#>>'{room_insights,dirty}')::int,1,'booked room can also need cleaning; inactive dirty rooms excluded');
select is((public.reservation_workspace('d3000000-0000-0000-0000-000000000001')#>>'{room_insights,cleaning}')::int,1,'cleaning in progress is distinct from dirty');
select is((public.reservation_workspace('d3000000-0000-0000-0000-000000000001')#>>'{room_insights,clean}')::int,12,'cleaning states cover every active room');
select is(jsonb_array_length(public.reservation_workspace('d3000000-0000-0000-0000-000000000001')->'calendar'),12,'calendar page remains bounded');
select is(public.reservation_workspace('d3000000-0000-0000-0000-000000000001','{"room_page":2}')->'room_insights',public.reservation_workspace('d3000000-0000-0000-0000-000000000001')->'room_insights','counts cover the whole property on every room page');
select is(public.reservation_workspace('d3000000-0000-0000-0000-000000000001','{"start":"2028-02-29"}')->'room_insights',public.reservation_workspace('d3000000-0000-0000-0000-000000000001')->'room_insights','current status stays explicitly today when browsing other dates');
select ok(exists(select 1 from jsonb_array_elements(public.reservation_workspace('d3000000-0000-0000-0000-000000000001')->'calendar')x where x->>'name'='P001'and x->>'current_stay'='d6000000-0000-0000-0000-000000000002'),'calendar includes current occupant even when their nightly hold ended today');
select is((public.reservation_workspace('d3000000-0000-0000-0000-000000000002')#>>'{room_insights,total}')::int,0,'summary never mixes properties');
reset role;
insert into public.unit_holds(tenant_id,property_id,unit_id,kind,during,reason)select tenant_id,property_id,id,'block',daterange((now()at time zone'Asia/Kolkata')::date,(now()at time zone'Asia/Kolkata')::date+1,'[)'),'Turnaround maintenance after departure'from public.accommodation_units where property_id='d3000000-0000-0000-0000-000000000001'and name='P001';
set local role authenticated;
select is((public.reservation_workspace('d3000000-0000-0000-0000-000000000001')#>>'{room_insights,blocked}')::int,2,'a blocked checkout-day room remains counted in blocked dates even before its guest leaves');
select is((public.reservation_workspace('d3000000-0000-0000-0000-000000000001')#>>'{room_insights,in_house}')::int,1,'blocked turnaround dates do not hide the departing in-house guest');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok($$select public.reservation_workspace('d3000000-0000-0000-0000-000000000001')$$,'42501',null,'reservation permission is still required');
reset role;
set local role anon;
select throws_ok($$select public.reservation_workspace('d3000000-0000-0000-0000-000000000001')$$,'42501',null,'anonymous calendar access remains denied');
select *from finish();
rollback;
