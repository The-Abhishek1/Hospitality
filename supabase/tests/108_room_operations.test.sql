begin;
select no_plan();

insert into auth.users (id, email) values
  ('61000000-0000-0000-0000-000000000001', 'owner@advanced-inventory.test'), ('61000000-0000-0000-0000-000000000002', 'clerk@advanced-inventory.test'),
  ('61000000-0000-0000-0000-000000000003', 'hk1@advanced-inventory.test'),   ('61000000-0000-0000-0000-000000000004', 'hk2@advanced-inventory.test'),
  ('61000000-0000-0000-0000-000000000005', 'nomember@advanced-inventory.test');
insert into public.tenants (id, name, slug) values ('62000000-0000-0000-0000-000000000001', 'Tenant 5', 'advanced-inventory');
insert into public.properties (id, tenant_id, name, property_type) values
  ('63000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000001', 'Prop 5', 'hotel');
insert into public.tenant_memberships (tenant_id, user_id, role)
select '62000000-0000-0000-0000-000000000001', u, case when u = '61000000-0000-0000-0000-000000000001' then 'owner' else 'member' end
from (values ('61000000-0000-0000-0000-000000000001'::uuid), ('61000000-0000-0000-0000-000000000002'), ('61000000-0000-0000-0000-000000000003'),
             ('61000000-0000-0000-0000-000000000004'), ('61000000-0000-0000-0000-000000000005')) v(u);
insert into public.property_memberships (property_id, tenant_id, user_id)
select '63000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000001', u
from (values ('61000000-0000-0000-0000-000000000002'::uuid), ('61000000-0000-0000-0000-000000000003'), ('61000000-0000-0000-0000-000000000004')) v(u);
insert into public.user_roles (property_id, user_id, role_id)
select '63000000-0000-0000-0000-000000000001', v.u, r.id
from (values ('61000000-0000-0000-0000-000000000002'::uuid, 'front_desk'), ('61000000-0000-0000-0000-000000000003', 'housekeeping'),
             ('61000000-0000-0000-0000-000000000004', 'housekeeping')) v(u, k)
join public.roles r on r.key = v.k and r.tenant_id is null;
insert into public.accommodation_types (id, tenant_id, property_id, name, max_occupancy, base_rate) values
  ('64000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000001', '63000000-0000-0000-0000-000000000001', 'Std', 2, 100);
insert into public.accommodation_units (id, tenant_id, property_id, type_id, name) values
  ('66000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000001', '63000000-0000-0000-0000-000000000001', '64000000-0000-0000-0000-000000000001', 'U1');
insert into public.guests (id, tenant_id, full_name) values ('65000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000001', 'Guest');


insert into public.property_settings(property_id,tenant_id,cleaning_checklist)values('63000000-0000-0000-0000-000000000001','62000000-0000-0000-0000-000000000001','["Inspect bathroom","Restock towels"]')on conflict(property_id)do update set cleaning_checklist=excluded.cleaning_checklist;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"61000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select set_config('test.room',public.inventory_save('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'rooms',null,null,'{"name":"Ops room","type_id":"64000000-0000-0000-0000-000000000001","active":true}')::text,true);
select set_config('test.version',(select version::text from public.accommodation_units where id=current_setting('test.room')::uuid),true);
select is((public.inventory_workspace('63000000-0000-0000-0000-000000000001')#>>'{stats,dirty}')::int,(select count(*)::int from public.accommodation_units where property_id='63000000-0000-0000-0000-000000000001'and active and housekeeping_status<>'clean'),'cleaning summary matches active rooms');
select set_config('test.job',public.inventory_cleaning_action('63000000-0000-0000-0000-000000000001',current_setting('test.room')::uuid,current_setting('test.version')::int,'69100000-0000-0000-0000-000000000001','start')::text,true);
select is((select status from public.tasks where id=current_setting('test.job')::uuid),'in_progress','quick start creates and starts cleaning work');
select is((select housekeeping_status from public.accommodation_units where id=current_setting('test.room')::uuid),'in_progress','quick start updates room cleanliness');
select is((select count(*)::int from public.task_checklists where task_id=current_setting('test.job')::uuid),2,'hotel checklist is preserved');
select is(public.inventory_cleaning_action('63000000-0000-0000-0000-000000000001',current_setting('test.room')::uuid,current_setting('test.version')::int,'69100000-0000-0000-0000-000000000001','start')::text,current_setting('test.job'),'retry returns the same cleaning job without duplicate work');
select is((select count(*)::int from public.tasks where unit_id=current_setting('test.room')::uuid and status in('open','in_progress')and kind='housekeeping'),1,'exactly one active cleaning task');
select throws_ok($$select public.inventory_cleaning_action('63000000-0000-0000-0000-000000000001',current_setting('test.room')::uuid,current_setting('test.version')::int,gen_random_uuid(),'complete')$$,'40001',null,'stale room version cannot finish cleaning');
select throws_ok($$select public.inventory_cleaning_action('63000000-0000-0000-0000-000000000001',current_setting('test.room')::uuid,(select version from public.accommodation_units where id=current_setting('test.room')::uuid),gen_random_uuid(),'complete')$$,'22023',null,'incomplete checklist blocks mark clean');
select is((public.inventory_detail('63000000-0000-0000-0000-000000000001','rooms',current_setting('test.room')::uuid)#>>'{item,cleaning_task,remaining}')::int,2,'room detail shows the remaining checklist');
do $$declare c record;begin for c in select id from public.task_checklists where task_id=current_setting('test.job')::uuid loop perform public.task_action('63000000-0000-0000-0000-000000000001',current_setting('test.job')::uuid,(select version from public.tasks where id=current_setting('test.job')::uuid),gen_random_uuid(),'check',jsonb_build_object('item',c.id,'done',true));end loop;end$$;
select lives_ok($$select public.inventory_cleaning_action('63000000-0000-0000-0000-000000000001',current_setting('test.room')::uuid,(select version from public.accommodation_units where id=current_setting('test.room')::uuid),'69100000-0000-0000-0000-000000000002','complete')$$,'completed checklist permits mark clean');
select is((select housekeeping_status from public.accommodation_units where id=current_setting('test.room')::uuid),'clean','completion marks the room clean');
select is((select status from public.tasks where id=current_setting('test.job')::uuid),'done','completion closes the original task');
select ok(public.inventory_detail('63000000-0000-0000-0000-000000000001','rooms',current_setting('test.room')::uuid)#>'{item,cleaning_task}'='null'::jsonb,'finished work is no longer listed as active cleaning');
select throws_ok($$select public.inventory_cleaning_action('63000000-0000-0000-0000-000000000001',current_setting('test.room')::uuid,(select version from public.accommodation_units where id=current_setting('test.room')::uuid),'69100000-0000-0000-0000-000000000001','complete')$$,'22023',null,'idempotency key cannot be reused for another action');
select throws_ok($$select public.inventory_cleaning_action('63000000-0000-0000-0000-000000000002',current_setting('test.room')::uuid,1,gen_random_uuid(),'start')$$,'42501',null,'cross-property cleaning is denied');
select set_config('request.jwt.claims','{"sub":"61000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok($$select public.inventory_cleaning_action('63000000-0000-0000-0000-000000000001',current_setting('test.room')::uuid,1,gen_random_uuid(),'start')$$,'42501',null,'front desk cannot bypass inventory and task permissions');
select ok(not has_function_privilege('authenticated','private.inventory_room_operations(uuid,uuid)','execute'),'private room helper cannot expose another hotel’s data');
select ok(not has_function_privilege('anon','public.inventory_cleaning_action(uuid,uuid,integer,uuid,text)','execute'),'anonymous cleaning actions are revoked');
select *from finish();
rollback;
