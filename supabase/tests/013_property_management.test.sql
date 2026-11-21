begin;
select plan(18);
insert into auth.users(id,email) values
('e1000000-0000-0000-0000-000000000001','owner@property.test'),
('e1000000-0000-0000-0000-000000000002','member@property.test');
insert into public.tenants(id,name,slug) values
('e2000000-0000-0000-0000-000000000001','Property business','property-business'),
('e2000000-0000-0000-0000-000000000002','Other business','other-property-business');
insert into public.tenant_memberships(tenant_id,user_id,role) values
('e2000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001','owner'),
('e2000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000002','member');
insert into public.subscriptions(tenant_id,plan_id,status) select 'e2000000-0000-0000-0000-000000000001',id,'active' from public.plans where key='starter';
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"e1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select public.create_property('e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','Hotel One','hotel','Asia/Kolkata','INR','{"city":"Chennai","contact_email":"desk@hotel.test"}')$$,'owner creates a property');
select is((select count(*)::int from public.properties where tenant_id='e2000000-0000-0000-0000-000000000001'),1,'property belongs to business');
select is((select city from public.properties where creation_request_id='e3000000-0000-0000-0000-000000000001'),'Chennai','saves contact/location settings');
select is(public.create_property('e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','Retry','hotel','UTC','USD'),(select id from public.properties where creation_request_id='e3000000-0000-0000-0000-000000000001'),'retry returns the original hotel');
select lives_ok($$select public.create_property('e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000002','Hotel Two','resort','Europe/London','GBP')$$,'owner creates second hotel');
select is((select count(*)::int from public.properties where tenant_id='e2000000-0000-0000-0000-000000000001'),2,'retry did not create duplicate');
select throws_ok($$select public.create_property('e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000003','Hotel Three','hotel','UTC','USD')$$,'53400',null,'starter plan enforces two-property cap');
select lives_ok($$update public.properties set name='Updated Hotel One' where creation_request_id='e3000000-0000-0000-0000-000000000001'$$,'owner can configure hotel');
select is((select name from public.properties where creation_request_id='e3000000-0000-0000-0000-000000000002'),'Hotel Two','editing hotel one leaves hotel two unchanged');
select throws_ok($$update public.properties set tenant_id='e2000000-0000-0000-0000-000000000002' where creation_request_id='e3000000-0000-0000-0000-000000000001'$$,'22023',null,'properties cannot move between businesses');
select lives_ok($$do $body$ declare p uuid; t uuid; g uuid; begin
 select id into p from public.properties where creation_request_id='e3000000-0000-0000-0000-000000000001';
 insert into public.accommodation_types(tenant_id,property_id,name,max_occupancy,base_rate) values('e2000000-0000-0000-0000-000000000001',p,'Standard',2,100) returning id into t;
 insert into public.accommodation_units(tenant_id,property_id,type_id,name) values('e2000000-0000-0000-0000-000000000001',p,t,'101');
 insert into public.guests(tenant_id,full_name) values('e2000000-0000-0000-0000-000000000001','Test Guest') returning id into g;
 perform public.create_reservation(p,g,t,'2027-03-01','2027-03-03');
end; $body$; $$,'hotel can receive bookings');
select throws_ok($$update public.properties set currency='USD' where creation_request_id='e3000000-0000-0000-0000-000000000001'$$,'22023',null,'currency is locked after booking');
select throws_ok($$update public.properties set timezone='Invalid/Timezone' where creation_request_id='e3000000-0000-0000-0000-000000000002'$$,'22023',null,'invalid timezone is rejected');
select throws_ok($$update public.properties set currency='123' where creation_request_id='e3000000-0000-0000-0000-000000000002'$$,'23514',null,'invalid currency format is rejected');
select set_config('request.jwt.claims','{"sub":"e1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok($$select public.create_property('e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000004','Member hotel','hotel','UTC','USD')$$,'42501',null,'ordinary staff cannot add hotels');
select is_empty($$update public.properties set name='Unauthorized' where tenant_id='e2000000-0000-0000-0000-000000000001' returning id$$,'ordinary staff cannot edit settings');
select throws_ok($$select public.create_property('e2000000-0000-0000-0000-000000000002','e3000000-0000-0000-0000-000000000005','Other hotel','hotel','UTC','USD')$$,'42501',null,'cannot add hotel to another business');
reset role;
set local role anon;
select throws_ok($$select public.create_property('e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000006','Anonymous hotel','hotel','UTC','USD')$$,'42501',null,'anonymous callers cannot add hotels');
select * from finish();
rollback;
