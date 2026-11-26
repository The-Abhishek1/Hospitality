begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select no_plan();
insert into auth.users(id,email)values('a1440000-0000-0000-0000-000000000001','cleaning-qa-owner@test.invalid'),('a1440000-0000-0000-0000-000000000002','cleaning-qa-other@test.invalid');
insert into public.tenants(id,name,slug)values('b1440000-0000-0000-0000-000000000001','Cleaning QA','cleaning-qa'),('b1440000-0000-0000-0000-000000000002','Other Import','other-import');
insert into public.properties(id,tenant_id,name,property_type)values('c1440000-0000-0000-0000-000000000001','b1440000-0000-0000-0000-000000000001','Import Hotel','hotel'),('c1440000-0000-0000-0000-000000000002','b1440000-0000-0000-0000-000000000002','Other Hotel','hotel');
insert into public.tenant_memberships(tenant_id,user_id,role)values('b1440000-0000-0000-0000-000000000001','a1440000-0000-0000-0000-000000000001','owner'),('b1440000-0000-0000-0000-000000000002','a1440000-0000-0000-0000-000000000002','owner');
\set pid c1440000-0000-0000-0000-000000000001
\set owner a1440000-0000-0000-0000-000000000001

insert into public.accommodation_types(id,tenant_id,property_id,name,base_rate,max_occupancy)values('d1440000-0000-0000-0000-000000000001','b1440000-0000-0000-0000-000000000001',:'pid','Cleaning type',1000,2);
insert into public.accommodation_units(id,tenant_id,property_id,type_id,name)values('d1440000-0000-0000-0000-000000000002','b1440000-0000-0000-0000-000000000001',:'pid','d1440000-0000-0000-0000-000000000001','Clean101');
update public.property_settings set cleaning_checklist=(select jsonb_agg('Category '||(n/8)||' › Step '||n order by n)from generate_series(0,199)n)where property_id=:'pid';
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select public.task_create_advanced(:'pid',gen_random_uuid(),'{"title":"Clean room","kind":"housekeeping","priority":"normal","unit":"d1440000-0000-0000-0000-000000000002","checklist":[]}')as taskid \gset
select is((public.task_detail(:'pid',:'taskid')#>>'{task,check_total}')::integer,200,'every room task receives all 200 saved steps even if the submitted checklist is empty');
select throws_ok(format('select public.set_task_status(%L,''done'')',:'taskid'),'22023',null,'room task cannot finish before all categories are complete');
reset role;
update public.property_settings set cleaning_checklist='["Changed future template"]'where property_id=:'pid';
select is((select count(*)::integer from public.task_checklists where task_id=:'taskid'),200,'changing hotel defaults does not rewrite a task snapshot');
update public.task_checklists set done=true where task_id=:'taskid';
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select lives_ok(format('select public.set_task_status(%L,''done'')',:'taskid'),'all checked steps allow completion');
reset role;
select is((select housekeeping_status from public.accommodation_units where id='d1440000-0000-0000-0000-000000000002'),'clean','successful completion marks the room clean');
select is(private.whatsapp_display_text('Arrival 2026-11-26 https://hotel.test/2026-11-26?day=2026-11-26 Departure 2026-11-27'),'Check-in 26-11-2026 https://hotel.test/2026-11-26?day=2026-11-26 Check-out 27-11-2026','WhatsApp date rendering preserves complete URLs');
select *from finish();rollback;
