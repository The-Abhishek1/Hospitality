begin;
select no_plan();

insert into auth.users (id, email) values
  ('61000000-0000-0000-0000-000000000001', 'owner@advanced-tasks.test'), ('61000000-0000-0000-0000-000000000002', 'clerk@advanced-tasks.test'),
  ('61000000-0000-0000-0000-000000000003', 'hk1@advanced-tasks.test'),   ('61000000-0000-0000-0000-000000000004', 'hk2@advanced-tasks.test'),
  ('61000000-0000-0000-0000-000000000005', 'nomember@advanced-tasks.test');
insert into public.tenants (id, name, slug) values ('62000000-0000-0000-0000-000000000001', 'Tenant 5', 'advanced-tasks');
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

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"61000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(jsonb_array_length(public.task_setup('63000000-0000-0000-0000-000000000001')->'rooms'),1,'task setup lists active hotel rooms');
select is(jsonb_array_length(public.task_setup('63000000-0000-0000-0000-000000000001')->'assignees'),3,'only owner and two eligible housekeepers can be assigned');
select set_config('test.payload','{"title":"Prepare U1","description":"Before arrival","kind":"housekeeping","priority":"high","unit":"66000000-0000-0000-0000-000000000001","target_minutes":30,"checklist":["Clean bathroom","Restock towels"]}',true);
select set_config('test.task',public.task_create_advanced('63000000-0000-0000-0000-000000000001','68000000-0000-0000-0000-000000000001',current_setting('test.payload')::jsonb)::text,true);
select is(public.task_create_advanced('63000000-0000-0000-0000-000000000001','68000000-0000-0000-0000-000000000001',current_setting('test.payload')::jsonb)::text,current_setting('test.task'),'creation retry returns original task');
select is((select count(*)::int from public.tasks),1,'idempotency prevents duplicate tasks');
select is((select housekeeping_status from public.accommodation_units where name='U1'),'dirty','room-linked cleaning starts with dirty room');
select is((public.task_detail('63000000-0000-0000-0000-000000000001',current_setting('test.task')::uuid)#>>'{task,check_total}')::int,2,'detail includes configured checklist');
select ok((select due_at=now()+interval '30 minutes'from public.tasks where id=current_setting('test.task')::uuid),'creation stores response target');
select throws_ok($$select public.task_create_advanced('63000000-0000-0000-0000-000000000001',gen_random_uuid(),current_setting('test.payload')::jsonb)$$,'23505',null,'room cannot have duplicate active cleaning tasks');
select throws_ok($$select public.task_create_advanced('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'{"title":"Invalid assignment","kind":"general","priority":"normal","assignee":"61000000-0000-0000-0000-000000000002"}')$$,'22023',null,'read-only front desk is not an eligible assignee');
select throws_ok($$select public.task_create_advanced('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'{"title":"Invalid checklist","kind":"general","priority":"normal","checklist":[""]}')$$,'22023',null,'invalid checklist rejects task atomically');
select is((select count(*)::int from public.tasks),1,'invalid checklist leaves no orphan task');
select throws_ok($$select public.task_action('63000000-0000-0000-0000-000000000001',current_setting('test.task')::uuid,0,gen_random_uuid(),'triage','{"priority":"urgent"}')$$,'40001',null,'stale task update rejected');
select throws_ok($$select public.task_detail('63000000-0000-0000-0000-000000000002',current_setting('test.task')::uuid)$$,'P0002',null,'task detail enforces property scope');
select set_config('request.jwt.claims','{"sub":"61000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select is((public.task_workspace('63000000-0000-0000-0000-000000000001')->>'total')::int,0,'read-only staff cannot browse unassigned tasks or counts');
select throws_ok($$select public.set_task_status(current_setting('test.task')::uuid,'in_progress')$$,'42501',null,'NULL assignee cannot bypass status authorization');
select throws_ok($$select public.task_create_advanced('63000000-0000-0000-0000-000000000001',gen_random_uuid(),current_setting('test.payload')::jsonb)$$,'42501',null,'front desk cannot create tasks');
select set_config('request.jwt.claims','{"sub":"61000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select is((public.task_workspace('63000000-0000-0000-0000-000000000001')->>'total')::int,1,'eligible worker sees claimable tasks');
select throws_ok($$select public.set_task_status(current_setting('test.task')::uuid,'done')$$,'42501',null,'unassigned task must be claimed before work updates');
select lives_ok($$select public.task_action('63000000-0000-0000-0000-000000000001',current_setting('test.task')::uuid,(select version from public.tasks where id=current_setting('test.task')::uuid),gen_random_uuid(),'claim')$$,'eligible worker claims task');
select lives_ok($$select public.task_action('63000000-0000-0000-0000-000000000001',current_setting('test.task')::uuid,(select version from public.tasks where id=current_setting('test.task')::uuid),gen_random_uuid(),'status','{"status":"in_progress"}')$$,'assigned worker starts work');
select is((select housekeeping_status from public.accommodation_units where name='U1'),'in_progress','room moves to cleaning');
select throws_ok($$select public.set_task_status(current_setting('test.task')::uuid,'done')$$,'22023',null,'legacy status API also enforces checklist completion');
select lives_ok($$update public.task_checklists set label='Bypass',done=true where task_id=current_setting('test.task')::uuid$$,'direct checklist update is filtered by RLS');
select is((select count(*)::int from public.task_checklists where task_id=current_setting('test.task')::uuid and done),0,'direct updates cannot bypass checklist workflow');
select throws_ok($$select public.task_action('63000000-0000-0000-0000-000000000001',current_setting('test.task')::uuid,(select version from public.tasks where id=current_setting('test.task')::uuid),gen_random_uuid(),'add_check','{"label":"Unauthorized"}')$$,'42501',null,'worker cannot alter checklist structure');
select lives_ok($$select public.task_action('63000000-0000-0000-0000-000000000001',current_setting('test.task')::uuid,0,'68000000-0000-0000-0000-000000000002','comment','{"body":"Bathroom ready"}')$$,'append-only comment survives stale version');
select lives_ok($$select public.task_action('63000000-0000-0000-0000-000000000001',current_setting('test.task')::uuid,0,'68000000-0000-0000-0000-000000000002','comment','{"body":"Bathroom ready"}')$$,'comment retry is idempotent');
select is(jsonb_array_length(public.task_detail('63000000-0000-0000-0000-000000000001',current_setting('test.task')::uuid)->'comments'),1,'only one internal comment recorded');
select set_config('request.jwt.claims','{"sub":"61000000-0000-0000-0000-000000000004","role":"authenticated"}',true);
select is((public.task_workspace('63000000-0000-0000-0000-000000000001')->>'total')::int,0,'other worker cannot see assigned task or counts');
select throws_ok($$select public.task_detail('63000000-0000-0000-0000-000000000001',current_setting('test.task')::uuid)$$,'42501',null,'other worker cannot open assigned work');
select is(public.task_workspace('63000000-0000-0000-0000-000000000001')#>'{rooms,0,task_id}','null'::jsonb,'room board does not expose private assigned task ID');
select set_config('request.jwt.claims','{"sub":"61000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
do $$declare c record;begin for c in select id from public.task_checklists where task_id=current_setting('test.task')::uuid loop perform public.task_action('63000000-0000-0000-0000-000000000001',current_setting('test.task')::uuid,(select version from public.tasks where id=current_setting('test.task')::uuid),gen_random_uuid(),'check',jsonb_build_object('item',c.id,'done',true));end loop;end $$;
select lives_ok($$select public.task_action('63000000-0000-0000-0000-000000000001',current_setting('test.task')::uuid,(select version from public.tasks where id=current_setting('test.task')::uuid),gen_random_uuid(),'status','{"status":"done"}')$$,'fully checked task can complete');
select is((select housekeeping_status from public.accommodation_units where name='U1'),'clean','completed room cleaning marks room clean');
select is((public.task_workspace('63000000-0000-0000-0000-000000000001')#>>'{stats,done_today}')::int,1,'today completion counts use hotel timezone');
select set_config('request.jwt.claims','{"sub":"61000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select public.task_action('63000000-0000-0000-0000-000000000001',current_setting('test.task')::uuid,(select version from public.tasks where id=current_setting('test.task')::uuid),gen_random_uuid(),'status','{"status":"open","reason":"Inspect again"}')$$,'manager reopens with reason');
select is((select count(*)::int from public.task_checklists where task_id=current_setting('test.task')::uuid and done),0,'reopen resets checklist progress');
select is((select housekeeping_status from public.accommodation_units where name='U1'),'dirty','reopened cleaning marks room dirty');
select lives_ok($$select public.task_action('63000000-0000-0000-0000-000000000001',current_setting('test.task')::uuid,(select version from public.tasks where id=current_setting('test.task')::uuid),gen_random_uuid(),'status','{"status":"in_progress"}')$$,'manager starts reopened task');
select throws_ok($$select public.task_action('63000000-0000-0000-0000-000000000001',current_setting('test.task')::uuid,(select version from public.tasks where id=current_setting('test.task')::uuid),gen_random_uuid(),'status','{"status":"cancelled"}')$$,'22023',null,'cancellation requires meaningful reason');
select lives_ok($$select public.task_action('63000000-0000-0000-0000-000000000001',current_setting('test.task')::uuid,(select version from public.tasks where id=current_setting('test.task')::uuid),gen_random_uuid(),'status','{"status":"cancelled","reason":"Duplicate work"}')$$,'manager cancels with reason');
select is((select housekeeping_status from public.accommodation_units where name='U1'),'dirty','cancelled in-progress cleaning leaves dirty room');
select public.task_create_advanced('63000000-0000-0000-0000-000000000001',gen_random_uuid(),jsonb_build_object('title','Page task '||i,'kind','general','priority','normal'))from generate_series(1,23)i;
select is((public.task_workspace('63000000-0000-0000-0000-000000000001','{"q":"Page task","page":2}')->>'total')::int,23,'queue count includes all matching work');
select is(jsonb_array_length(public.task_workspace('63000000-0000-0000-0000-000000000001','{"q":"Page task","page":2}')->'rows'),3,'second queue page returns remaining work');
select ok(not has_function_privilege('anon','public.task_action(uuid,uuid,integer,uuid,text,jsonb)','execute'),'anonymous task mutations are revoked');
select public.create_reservation('63000000-0000-0000-0000-000000000001','65000000-0000-0000-0000-000000000001','64000000-0000-0000-0000-000000000001',(now()at time zone(select timezone from public.properties where id='63000000-0000-0000-0000-000000000001'))::date,(now()at time zone(select timezone from public.properties where id='63000000-0000-0000-0000-000000000001'))::date+1);
select is((public.task_workspace('63000000-0000-0000-0000-000000000001')#>>'{room_stats,arrival_attention}')::int,1,'dirty room with arrival today is flagged for attention');
select is(jsonb_array_length(public.task_workspace('63000000-0000-0000-0000-000000000001','{"room_state":"unallocated"}')->'rooms'),1,'dirty room without active cleaning appears in unallocated view');
select set_config('request.jwt.claims','{"sub":"61000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select is((public.task_workspace('63000000-0000-0000-0000-000000000001')#>>'{room_stats,dirty}')::int,1,'read-only front desk can still see room readiness');
select * from finish();
rollback;
