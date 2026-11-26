begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select no_plan();
insert into auth.users(id,email)values('a1370000-0000-0000-0000-000000000001','menu-import-owner@test.invalid'),('a1370000-0000-0000-0000-000000000002','menu-import-other@test.invalid');
insert into public.tenants(id,name,slug)values('b1370000-0000-0000-0000-000000000001','Menu Import','menu-import'),('b1370000-0000-0000-0000-000000000002','Other Import','other-import');
insert into public.properties(id,tenant_id,name,property_type)values('c1370000-0000-0000-0000-000000000001','b1370000-0000-0000-0000-000000000001','Import Hotel','hotel'),('c1370000-0000-0000-0000-000000000002','b1370000-0000-0000-0000-000000000002','Other Hotel','hotel');
insert into public.tenant_memberships(tenant_id,user_id,role)values('b1370000-0000-0000-0000-000000000001','a1370000-0000-0000-0000-000000000001','owner'),('b1370000-0000-0000-0000-000000000002','a1370000-0000-0000-0000-000000000002','owner');
\set pid c1370000-0000-0000-0000-000000000001
\set owner a1370000-0000-0000-0000-000000000001
create function pg_temp.item(p_name text,p_row integer default 2)returns jsonb language sql as $$select jsonb_build_object('row',p_row,'details',jsonb_build_object('name',p_name,'category','Imported mains','price','150','tax','5','dietary_type','veg','service_scope','both','pricing_mode','single','description','Imported dish','dietary_notes','','prep_minutes','10','active',false,'variants','[]'::jsonb))$$;
select jsonb_build_array(pg_temp.item('Paneer tikka'),pg_temp.item('Soup',3)||jsonb_build_object('details',(pg_temp.item('Soup',3)->'details')||jsonb_build_object('pricing_mode','sizes','variants',jsonb_build_array(jsonb_build_object('id','d1370000-0000-0000-0000-000000000001','label','Small','price','90'),jsonb_build_object('id','d1370000-0000-0000-0000-000000000002','label','Large','price','160')))))as payload \gset
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select is((public.food_menu_import_preview(:'pid',:'payload')->>'new_count')::integer,2,'preview identifies the two new items');
select is((select count(*)::integer from public.menu_items where property_id=:'pid'),0,'preview saves no menu items');
select public.food_menu_import(:'pid','e1370000-0000-0000-0000-000000000001',:'payload','skip')as result \gset
select is((:'result'::jsonb->>'created')::integer,2,'one confirmation imports the whole menu');
select is((select count(*)::integer from public.menu_categories where property_id=:'pid'),1,'matching category names are created only once');
select is((select count(*)::integer from public.menu_items where property_id=:'pid'and not active),2,'imported availability is respected');
select is((select jsonb_array_length(public.food_menu_item(:'pid',id)#>'{item,variants}')from public.menu_items where property_id=:'pid'and name='Soup'),2,'sizes import into real variant records');
select is((select price from public.menu_items where property_id=:'pid'and name='Soup'),90::numeric,'variant item starts at its lowest size price');
select is(public.food_menu_import(:'pid','e1370000-0000-0000-0000-000000000001',:'payload','skip'),:'result'::jsonb,'retry returns the original batch result');
select is((select count(*)::integer from public.menu_items where property_id=:'pid'),2,'retry does not add duplicate dishes');
select throws_ok(format('select public.food_menu_import(%L,%L,%L,%L)',:'pid','e1370000-0000-0000-0000-000000000001',:'payload','error'),'40001',null,'request IDs cannot be reused for a different import policy');
select is((public.food_menu_import_preview(:'pid',jsonb_build_array(pg_temp.item('PANEER TIKKA')))->>'existing_count')::integer,1,'existing names are matched without case differences');
select is((public.food_menu_import(:'pid',gen_random_uuid(),jsonb_build_array(pg_temp.item('Paneer tikka'),pg_temp.item('New curry',3)),'skip')->>'created')::integer,1,'skip policy imports only new dishes');
select is((select price from public.menu_items where property_id=:'pid'and name='Paneer tikka'),150::numeric,'an existing price is preserved');
select throws_ok(format('select public.food_menu_import(%L,gen_random_uuid(),%L,%L)',:'pid',jsonb_build_array(pg_temp.item('Rolled back dish'),pg_temp.item('Paneer tikka',3))::text,'error'),'23505',null,'stop policy rejects any duplicate in the batch');
select is((select count(*)::integer from public.menu_items where property_id=:'pid'and name='Rolled back dish'),0,'duplicate failure rolls back earlier rows in the same batch');
select throws_ok(format('select public.food_menu_import(%L,gen_random_uuid(),%L,%L)',:'pid',jsonb_build_array(pg_temp.item('Before invalid row'),jsonb_set(pg_temp.item('Invalid category',3),'{details,category}','"x"'))::text,'skip'),'22023',null,'item-form validation also protects bulk imports');
select is((select count(*)::integer from public.menu_items where property_id=:'pid'and name='Before invalid row'),0,'invalid rows leave no partial menu import');
select throws_ok(format('select public.food_menu_import(%L,gen_random_uuid(),%L,%L)',:'pid',jsonb_build_array(pg_temp.item('Repeated'),pg_temp.item('Repeated',3))::text,'skip'),'22023',null,'ungrouped duplicate item names cannot bypass the parser');
select id as soup from public.menu_items where property_id=:'pid'and name='Soup' \gset
select public.order_menu_lifecycle(:'pid',:'soup',1,gen_random_uuid(),'delete');
select is(public.food_menu_import_preview(:'pid',jsonb_build_array(pg_temp.item('Soup')))#>>'{rows,0,state}','deleted','preview identifies deleted names rather than silently restoring them');
select is((public.food_menu_import(:'pid',gen_random_uuid(),jsonb_build_array(pg_temp.item('Soup')),'skip')->>'skipped')::integer,1,'deleted dishes remain deleted');
select throws_ok($$select public.food_menu_import_preview('c1370000-0000-0000-0000-000000000002',jsonb_build_array(pg_temp.item('Foreign menu')))$$,'42501',null,'preview cannot read another hotel’s menu');
select throws_ok($$select public.food_menu_import('c1370000-0000-0000-0000-000000000002',gen_random_uuid(),jsonb_build_array(pg_temp.item('Foreign menu')),'skip')$$,'42501',null,'imports cannot write to another hotel');
select throws_ok(format('select public.food_menu_import(%L,gen_random_uuid(),%L,%L)',:'pid','[]','skip'),'22023',null,'empty imports are rejected');
reset role;
select ok(not has_table_privilege('authenticated','private.food_menu_import_commands','select'),'batch payloads are not directly readable by browser clients');
select ok(not has_function_privilege('anon','public.food_menu_import(uuid,uuid,jsonb,text)','execute'),'anonymous visitors cannot import a menu');
select *from finish();
rollback;
