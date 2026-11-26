begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select no_plan();
insert into auth.users(id,email)values('a1390000-0000-0000-0000-000000000001','staff-records-owner@test.invalid'),('a1390000-0000-0000-0000-000000000002','staff-records-other@test.invalid');
insert into public.tenants(id,name,slug)values('b1390000-0000-0000-0000-000000000001','Staff Records','staff-records'),('b1390000-0000-0000-0000-000000000002','Other Import','other-import');
insert into public.properties(id,tenant_id,name,property_type)values('c1390000-0000-0000-0000-000000000001','b1390000-0000-0000-0000-000000000001','Import Hotel','hotel'),('c1390000-0000-0000-0000-000000000002','b1390000-0000-0000-0000-000000000002','Other Hotel','hotel');
insert into public.tenant_memberships(tenant_id,user_id,role)values('b1390000-0000-0000-0000-000000000001','a1390000-0000-0000-0000-000000000001','owner'),('b1390000-0000-0000-0000-000000000002','a1390000-0000-0000-0000-000000000002','owner');
\set pid c1390000-0000-0000-0000-000000000001
\set owner a1390000-0000-0000-0000-000000000001
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select lives_ok(format('select public.staff_manage(%L,%L,''create'',%L)',:'pid','e1390000-0000-0000-0000-000000000001',jsonb_build_object('code','EMP001','full_name','Staff Example','department','Housekeeping','joined_on',current_date-10,'monthly_salary','30000')::text),'employee and salary are saved');
select (public.staff_workspace(:'pid',current_date)#>>'{rows,0,id}')as staffid \gset
select public.staff_manage(:'pid',gen_random_uuid(),'attendance',jsonb_build_object('ids',jsonb_build_array(:'staffid'),'day',current_date,'status','present'));
select is((public.staff_workspace(:'pid',current_date)#>>'{rows,0,present}')::integer,1,'attendance appears in sheet');
select public.staff_manage(:'pid',gen_random_uuid(),'salary',jsonb_build_object('ids',jsonb_build_array(:'staffid'),'month',date_trunc('month',current_date)::date,'amount','31000'));
select is((public.staff_workspace(:'pid',current_date)#>>'{rows,0,monthly_salary}')::numeric,31000::numeric,'selected employee salary updated');
select throws_ok(format('select public.staff_workspace(%L,current_date)', 'c1390000-0000-0000-0000-000000000002'),'42501',null,'salary is isolated between hotels');

select throws_ok(format('select public.staff_manage(%L,gen_random_uuid(),''attendance'',%L)',:'pid',jsonb_build_object('ids',jsonb_build_array(:'staffid'),'day',current_date,'status','absent')::text),'22023',null,'overwriting marked attendance needs an explicit correction');
select public.staff_manage(:'pid',gen_random_uuid(),'attendance',jsonb_build_object('ids',jsonb_build_array(:'staffid'),'day',current_date,'status','half_day','replace',true));
select is((public.staff_workspace(:'pid',current_date)#>>'{rows,0,half_day}')::integer,1,'half-day corrections persist');
select public.staff_manage(:'pid',gen_random_uuid(),'leave',jsonb_build_object('staff_id',:'staffid','from',current_date+5,'to',current_date+6,'paid',false,'reason','Planned personal leave'));
select (public.staff_workspace(:'pid',current_date+5)#>>'{leaves,0,id}')as leaveid \gset
select throws_ok(format('select public.staff_manage(%L,gen_random_uuid(),''leave'',%L)',:'pid',jsonb_build_object('staff_id',:'staffid','from',current_date+5,'to',current_date+6,'paid',true,'reason','Duplicate leave')::text),'22023',null,'overlapping leave cannot duplicate deductions');
select public.staff_manage(:'pid',gen_random_uuid(),'review_leave',jsonb_build_object('id',:'leaveid','version',1,'status','approved'));
select is(public.staff_workspace(:'pid',current_date+5)#>>'{leaves,0,status}','approved','manager approval is recorded');
select is((public.staff_workspace(:'pid',current_date+5)#>>'{rows,0,unpaid}')::integer,2,'approved unpaid leave marks both days in attendance');
select is((public.staff_workspace(:'pid',current_date)->>'days')::integer,extract(day from(date_trunc('month',current_date)+interval '1 month - 1 day'))::integer,'salary denominator uses actual calendar days');
select throws_ok(format('select public.staff_manage(%L,gen_random_uuid(),''import'',%L)',:'pid',jsonb_build_object('rows',jsonb_build_array(jsonb_build_object('code','ROLLBACK','full_name','Should Roll Back','joined_on',current_date),jsonb_build_object('code','INVALID','full_name','X','joined_on',current_date)))::text),'22023',null,'invalid staff import is rejected atomically');
select is((public.staff_workspace(:'pid',current_date,'ROLLBACK')->>'total')::integer,0,'earlier import rows are rolled back after an invalid row');
select throws_ok(format('select public.staff_manage(%L,gen_random_uuid(),''salary'',%L)',:'pid',jsonb_build_object('ids',jsonb_build_array(gen_random_uuid()),'month',date_trunc('month',current_date)::date,'amount',100)::text),'22023',null,'salary updates cannot target unknown or foreign staff');
select *from finish();rollback;
