begin;
select no_plan();

insert into auth.users (id, email) values
  ('81000000-0000-0000-0000-000000000001', 'owner@reports.test'), ('81000000-0000-0000-0000-000000000002', 'clerk@reports.test'),
  ('81000000-0000-0000-0000-000000000003', 'cook@reports.test'),  ('81000000-0000-0000-0000-000000000004', 'acct@reports.test'),
  ('81000000-0000-0000-0000-000000000005', 'hk@reports.test');
insert into public.tenants (id, name, slug) values ('82000000-0000-0000-0000-000000000001', 'Tenant 7', 'report-test');
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

update public.properties set timezone='UTC' where id='83000000-0000-0000-0000-000000000001';
insert into public.accommodation_units(tenant_id,property_id,type_id,name)values('82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','84000000-0000-0000-0000-000000000001','U2');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select set_config('test.res',public.create_reservation('83000000-0000-0000-0000-000000000001','85000000-0000-0000-0000-000000000001','84000000-0000-0000-0000-000000000001','2027-01-10','2027-01-12',1,0)::text,true);
reset role;
update public.reservations set total_amount=200.01 where id=current_setting('test.res')::uuid;
insert into public.unit_holds(tenant_id,property_id,unit_id,during,kind,reason)
select tenant_id,property_id,id,'[2027-01-11,2027-01-12)'::daterange,'block','Maintenance'from public.accommodation_units where property_id='83000000-0000-0000-0000-000000000001' and id not in(select unit_id from public.unit_holds where reservation_id=current_setting('test.res')::uuid);
insert into public.folios(id,tenant_id,property_id,reservation_id,currency)values('88000000-0000-0000-0000-000000000001','82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001',current_setting('test.res')::uuid,'INR');
insert into public.payments(id,tenant_id,property_id,folio_id,amount,method,created_at)values
('89000000-0000-0000-0000-000000000001','82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','88000000-0000-0000-0000-000000000001',80,'card','2027-01-05 12:00Z'),
('89000000-0000-0000-0000-000000000002','82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','88000000-0000-0000-0000-000000000001',300,'cash','2027-01-10 12:00Z');
insert into public.refunds(tenant_id,property_id,payment_id,amount,reason,created_at)values('82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','89000000-0000-0000-0000-000000000001',30,'Report fixture','2027-01-11 12:00Z');
insert into public.folio_items(tenant_id,property_id,folio_id,kind,description,amount,business_date)values
('82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','88000000-0000-0000-0000-000000000001','room','Night one',100.01,'2027-01-10'),
('82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','88000000-0000-0000-0000-000000000001','adjustment','Discount',-5,'2027-01-12');
insert into public.tasks(tenant_id,property_id,title,status,created_at,completed_at,due_at)values
('82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','Earlier task','done','2027-01-01 12:00Z','2027-01-11 12:00Z','2027-01-12 12:00Z'),
('82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','No target task','done','2027-01-11 12:00Z','2027-01-11 13:00Z',null),
('82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','Old backlog','open','2020-01-01 12:00Z',null,'2020-01-02 12:00Z');
set local role authenticated;
select set_config('test.report',public.hotel_report('83000000-0000-0000-0000-000000000001','2027-01-10','2027-01-12')::text,true);
select is((current_setting('test.report')::jsonb->>'days')::integer,3,'range counts both endpoints');
select is(jsonb_array_length(current_setting('test.report')::jsonb->'daily'),3,'one row for each hotel business day');
select is((current_setting('test.report')::jsonb#>>'{summary,available_room_nights}')::integer,5,'active room blocks reduce reference capacity');
select is((current_setting('test.report')::jsonb#>>'{summary,booked_room_nights}')::integer,2,'checkout day is excluded from room nights');
select is((current_setting('test.report')::jsonb#>>'{summary,occupancy}')::numeric,40::numeric,'scheduled occupancy uses unblocked room nights');
select is((current_setting('test.report')::jsonb#>>'{summary,booked_room_value}')::numeric,200.01,'allocated room value reconciles to stay total');
select is((current_setting('test.report')::jsonb#>>'{daily,0,booked_room_value}')::numeric,100.01,'remainder cents allocated to earliest night');
select is((current_setting('test.report')::jsonb#>>'{daily,1,booked_room_value}')::numeric,100.00,'remaining night preserves exact cents');
select is((current_setting('test.report')::jsonb#>>'{summary,receipts}')::numeric,300::numeric,'receipts use transaction dates');
select is((current_setting('test.report')::jsonb#>>'{summary,refunds}')::numeric,30::numeric,'refunds include payments received before range');
select is((current_setting('test.report')::jsonb#>>'{summary,net_cash}')::numeric,270::numeric,'cash subtracts refunds independently from booked value');
select is((select (x->>'refunded')::numeric from jsonb_array_elements(current_setting('test.report')::jsonb->'payment_methods')x where x->>'method'='card'),30::numeric,'refund-only method remains visible');
select is((current_setting('test.report')::jsonb->>'previous_from'),'2027-01-07','comparison starts exactly one equal period earlier');
select is((current_setting('test.report')::jsonb->>'previous_to'),'2027-01-09','comparison has no overlapping dates');
select is((select count(*)::integer from public.folios),1,'report does not create additional folios');
select is((select count(*)::integer from public.folio_items),2,'report does not post additional room charges');
select is((current_setting('test.report')::jsonb#>>'{summary,folio_charges}')::numeric,95.01,'signed posted charges remain distinct from booking and cash');
select is((current_setting('test.report')::jsonb#>>'{operations,tasks,completed}')::integer,2,'completed tasks include work created before the selected period');
select is((current_setting('test.report')::jsonb#>>'{operations,tasks,created}')::integer,1,'creation cohort differs from completion cohort');
select is((current_setting('test.report')::jsonb#>>'{operations,tasks,completed_with_target}')::integer,1,'untargeted work excluded from target denominator');
select is((current_setting('test.report')::jsonb#>>'{operations,tasks,within_target}')::integer,1,'on-time completion uses each task target');
select is((current_setting('test.report')::jsonb#>>'{operations,tasks,overdue_now}')::integer,1,'current overdue workload includes older creation dates');
select lives_ok($$select public.hotel_report('83000000-0000-0000-0000-000000000001','2024-01-01','2024-12-31')$$,'366-day leap-year range accepted');
select throws_ok($$select public.hotel_report('83000000-0000-0000-0000-000000000001','2024-01-01','2025-01-01')$$,'22023',null,'367-day range rejected');
select throws_ok($$select public.hotel_report('83000000-0000-0000-0000-000000000001','2027-01-12','2027-01-10')$$,'22023',null,'reversed range rejected');
select throws_ok($$select public.hotel_report('83000000-0000-0000-0000-000000000099')$$,'42501',null,'inaccessible hotel rejected');
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select set_config('test.kitchen',public.hotel_report('83000000-0000-0000-0000-000000000001','2027-01-10','2027-01-12')::text,true);
select is((current_setting('test.kitchen')::jsonb#>>'{capabilities,calendar}')::boolean,false,'kitchen has no reservation aggregate access');
select is(current_setting('test.kitchen')::jsonb#>'{summary,receipts}','null'::jsonb,'kitchen receives no cash totals');
select is(current_setting('test.kitchen')::jsonb->'payment_methods','[]'::jsonb,'kitchen receives no payment breakdown');
select is(current_setting('test.kitchen')::jsonb->'sources','[]'::jsonb,'kitchen receives no source cohorts');
select is(current_setting('test.kitchen')::jsonb#>'{operations,tasks}','null'::jsonb,'kitchen receives no hotelwide staff task data');
select ok(current_setting('test.kitchen')::jsonb#>'{operations,orders}'<>'null'::jsonb,'kitchen can report order outcomes');
select is((public.workspace_permissions('83000000-0000-0000-0000-000000000001')->>'reports')::boolean,true,'kitchen navigation includes authorized reports');
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000004","role":"authenticated"}',true);
reset role;
delete from public.user_roles where user_id='81000000-0000-0000-0000-000000000004';
insert into public.roles(id,tenant_id,key,name)values('8a000000-0000-0000-0000-000000000001','82000000-0000-0000-0000-000000000001','reports-finance-only','Finance only');
insert into public.role_permissions(role_id,permission_key)values('8a000000-0000-0000-0000-000000000001','finance.read');
insert into public.user_roles(property_id,user_id,role_id)values('83000000-0000-0000-0000-000000000001','81000000-0000-0000-0000-000000000004','8a000000-0000-0000-0000-000000000001');
set local role authenticated;
select is((public.hotel_report('83000000-0000-0000-0000-000000000001')#>>'{capabilities,link_reservations}')::boolean,false,'finance-only aggregates do not authorize guest reservation links');
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select throws_ok($$select public.hotel_report('83000000-0000-0000-0000-000000000001')$$,'42501',null,'own-task access does not authorize hotelwide reporting');
select is((public.workspace_permissions('83000000-0000-0000-0000-000000000001')->>'reports')::boolean,false,'report link hidden from own-task-only staff');
reset role;
select ok(not has_function_privilege('anon','public.hotel_report(uuid,date,date)','execute'),'anonymous cannot execute hotel reports');
select ok(not has_function_privilege('authenticated','private.report_slice(uuid,date,date,jsonb,boolean)','execute'),'internal aggregation cannot bypass capabilities');
-- The same transaction is included/excluded according to the hotel's local midnight.
update public.properties set timezone='Asia/Kolkata'where id='83000000-0000-0000-0000-000000000001';
insert into public.payments(tenant_id,property_id,folio_id,amount,method,created_at)values('82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','88000000-0000-0000-0000-000000000001',7,'upi','2027-01-09 18:45Z');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is((public.hotel_report('83000000-0000-0000-0000-000000000001','2027-01-10','2027-01-10')#>>'{summary,receipts}')::numeric,307::numeric,'hotel midnight includes UTC previous-evening payments');
reset role;
update public.properties set timezone='America/New_York'where id='83000000-0000-0000-0000-000000000001';
insert into public.payments(tenant_id,property_id,folio_id,amount,method,created_at)values
('82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','88000000-0000-0000-0000-000000000001',11,'cash','2027-03-14 05:00Z'),
('82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','88000000-0000-0000-0000-000000000001',13,'cash','2027-03-15 03:59Z'),
('82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','88000000-0000-0000-0000-000000000001',17,'cash','2027-03-15 04:00Z');
set local role authenticated;
select is((public.hotel_report('83000000-0000-0000-0000-000000000001','2027-03-14','2027-03-14')#>>'{summary,receipts}')::numeric,24::numeric,'spring-forward business day ends at local midnight after 23 hours');
select is((public.hotel_report('83000000-0000-0000-0000-000000000001','2027-01-11','2027-01-11')#>>'{summary,net_cash}')::numeric,-30::numeric,'refund-only date reports negative net cash');
select * from finish();
rollback;
