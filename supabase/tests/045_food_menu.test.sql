begin;
select no_plan();

insert into auth.users (id, email) values
  ('81000000-0000-0000-0000-000000000001', 'owner@advanced-orders.test'), ('81000000-0000-0000-0000-000000000002', 'clerk@advanced-orders.test'),
  ('81000000-0000-0000-0000-000000000003', 'cook@advanced-orders.test'),  ('81000000-0000-0000-0000-000000000004', 'acct@advanced-orders.test'),
  ('81000000-0000-0000-0000-000000000005', 'hk@advanced-orders.test');
insert into public.tenants (id, name, slug) values ('82000000-0000-0000-0000-000000000001', 'Tenant 7', 'advanced-orders');
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


insert into public.properties(id,tenant_id,name,property_type)values('83000000-0000-0000-0000-000000000002','82000000-0000-0000-0000-000000000001','Other hotel','hotel');
insert into public.food_menu_photos(id,property_id,storage_path,url,mime_type)values
 ('89000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','hotel/food.jpg','https://example.test/food.jpg','image/jpeg'),
 ('89000000-0000-0000-0000-000000000002','83000000-0000-0000-0000-000000000002','other/food.jpg','https://example.test/other.jpg','image/jpeg');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(public.food_menu_workspace('83000000-0000-0000-0000-000000000001')->>'page_size','10','owner catalog defaults to ten items');
select is(public.food_menu_item('83000000-0000-0000-0000-000000000001','87000000-0000-0000-0000-000000000001')#>>'{item,dietary_type}','not_specified','legacy food has no invented dietary claims');
select set_config('food.details','{"name":"Paneer platter","category":"Mains","price":"0","tax":"5","active":true,"dietary_type":"veg","service_scope":"both","pricing_mode":"sizes","image_id":"89000000-0000-0000-0000-000000000001","variants":[{"id":"8a000000-0000-0000-0000-000000000001","label":"Half","price":"100"},{"id":"8a000000-0000-0000-0000-000000000002","label":"Full","price":"180"}]}',true);
select set_config('food.item',public.order_menu_save('83000000-0000-0000-0000-000000000001','8b000000-0000-0000-0000-000000000001',null,null,current_setting('food.details')::jsonb)::text,true);
select is(public.order_menu_save('83000000-0000-0000-0000-000000000001','8b000000-0000-0000-0000-000000000001',null,null,current_setting('food.details')::jsonb)::text,current_setting('food.item'),'size creation retries return same item');
select is(public.food_menu_item('83000000-0000-0000-0000-000000000001',current_setting('food.item')::uuid)#>>'{item,price}','100.00','listing starts at lowest size price');
select is(public.food_menu_item('83000000-0000-0000-0000-000000000001',current_setting('food.item')::uuid)#>>'{item,image_url}','https://example.test/food.jpg','owned food photo is included for display');
select throws_ok($$select public.order_menu_save('83000000-0000-0000-0000-000000000001',gen_random_uuid(),null,null,current_setting('food.details')::jsonb||'{"name":"Foreign image","image_id":"89000000-0000-0000-0000-000000000002"}')$$,'22023',null,'cannot attach another hotel photo');
select throws_ok($$select public.order_menu_save('83000000-0000-0000-0000-000000000001',gen_random_uuid(),null,null,current_setting('food.details')::jsonb||'{"name":"Stolen sizes"}')$$,'22023',null,'cannot attach sizes belonging to another item');
select throws_ok($$select public.order_menu_save('83000000-0000-0000-0000-000000000001',gen_random_uuid(),current_setting('food.item')::uuid,0,current_setting('food.details')::jsonb)$$,'40001',null,'stale parent edit rejected before sizes change');
select set_config('food.lines',jsonb_build_array(jsonb_build_object('menu_item_id',current_setting('food.item'),'version',1,'variant_id','8a000000-0000-0000-0000-000000000001','variant_version',1,'quantity',2),jsonb_build_object('menu_item_id',current_setting('food.item'),'version',1,'variant_id','8a000000-0000-0000-0000-000000000002','variant_version',1,'quantity',1))::text,true);
select set_config('food.order',public.orders_create('83000000-0000-0000-0000-000000000001',gen_random_uuid(),jsonb_build_object('kind','restaurant','items',current_setting('food.lines')::jsonb,'quote','399.00'))::text,true);
select is((select total from public.orders where id=current_setting('food.order')::uuid),399.00::numeric,'two sizes of one dish have authoritative price and tax');
select is((select count(*)::int from public.order_items where order_id=current_setting('food.order')::uuid),2,'two chosen sizes are separate order lines');
select is((select name_snapshot from public.order_items where order_id=current_setting('food.order')::uuid and variant_label='Full'),'Paneer platter · Full','size is visible on kitchen and bill snapshots');
select throws_ok($$select public.orders_create('83000000-0000-0000-0000-000000000001',gen_random_uuid(),jsonb_build_object('kind','restaurant','quote','105','items',jsonb_build_array(jsonb_build_object('menu_item_id',current_setting('food.item'),'version',1,'quantity',1))))$$,'40001',null,'size choice is mandatory');
select throws_ok($$select public.orders_create('83000000-0000-0000-0000-000000000001',gen_random_uuid(),jsonb_build_object('kind','restaurant','quote','1','items',current_setting('food.lines')::jsonb))$$,'40001',null,'tampered size total rejected');
select throws_ok($$select public.orders_create('83000000-0000-0000-0000-000000000001',gen_random_uuid(),jsonb_build_object('kind','restaurant','quote','399','items',jsonb_set(current_setting('food.lines')::jsonb,'{0,variant_version}','0')))$$,'40001',null,'stale size price rejected');
select throws_ok($$select public.place_order('83000000-0000-0000-0000-000000000001','restaurant',jsonb_set(current_setting('food.lines')::jsonb,'{0,quantity}','"bad"'))$$,'22023',null,'malformed quantities receive a validation error');
select set_config('food.restaurant',public.order_menu_save('83000000-0000-0000-0000-000000000001',gen_random_uuid(),null,null,'{"name":"Restaurant steak","category":"Mains","price":"500","tax":"0","dietary_type":"non_veg","service_scope":"restaurant","pricing_mode":"single"}')::text,true);
select throws_ok($$select public.place_order('83000000-0000-0000-0000-000000000001','room_service',jsonb_build_array(jsonb_build_object('menu_item_id',current_setting('food.restaurant'),'quantity',1)),null)$$,'22023',null,'room service cannot bypass destination');
select set_config('food.stay',public.create_reservation('83000000-0000-0000-0000-000000000001','85000000-0000-0000-0000-000000000001','84000000-0000-0000-0000-000000000001',(now()at time zone 'Asia/Kolkata')::date,(now()at time zone 'Asia/Kolkata')::date+1)::text,true);
select public.check_in_reservation(current_setting('food.stay')::uuid);
select set_config('food.token',public.create_guest_portal_link(current_setting('food.stay')::uuid),true);
set local role anon;
select is((select count(*)::int from jsonb_array_elements(public.portal_workspace(current_setting('food.token'))->'menu')m where m->>'id'=current_setting('food.restaurant')),0,'restaurant-only items never shown in room-service catalog');
select is(public.portal_workspace(current_setting('food.token'))->>'menu_page_size','10','guest catalog is paginated in groups of ten');
select throws_ok($$select public.portal_command(current_setting('food.token'),gen_random_uuid(),'order',jsonb_build_object('currency','INR','total','500','items',jsonb_build_array(jsonb_build_object('menu_item_id',current_setting('food.restaurant'),'quantity',1,'version',1))))$$,'22023',null,'guest cannot order hidden restaurant-only dish');
select set_config('food.guest_request',gen_random_uuid()::text,true);
select set_config('food.guest_payload',jsonb_build_object('currency','INR','total','399.00','items',current_setting('food.lines')::jsonb)::text,true);
select set_config('food.guest_order',public.portal_command(current_setting('food.token'),current_setting('food.guest_request')::uuid,'order',current_setting('food.guest_payload')::jsonb)->>'id',true);
select is(public.portal_workspace(current_setting('food.token'))#>>'{orders,0,total}','399.00','guest sizes calculate correct totals');
select ok(not has_table_privilege('anon','public.food_menu_photos','insert'),'guests cannot write photo metadata');
select ok(not has_function_privilege('anon','public.food_menu_workspace(uuid,jsonb)','execute'),'guests cannot browse manager catalog');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select set_config('food.delete_request',gen_random_uuid()::text,true);
select lives_ok($$select public.order_menu_lifecycle('83000000-0000-0000-0000-000000000001',current_setting('food.item')::uuid,1,current_setting('food.delete_request')::uuid,'delete')$$,'owner can delete an ordered food item safely');
select lives_ok($$select public.order_menu_lifecycle('83000000-0000-0000-0000-000000000001',current_setting('food.item')::uuid,1,current_setting('food.delete_request')::uuid,'delete')$$,'delete retries are idempotent');
select is((select total from public.orders where id=current_setting('food.order')::uuid),399.00::numeric,'deletion preserves original order amount');
select is((select count(*)::int from public.order_items where order_id=current_setting('food.order')::uuid),2,'deletion preserves kitchen lines');
select is(public.food_menu_workspace('83000000-0000-0000-0000-000000000001','{"state":"deleted"}')->>'total','1','deleted item is discoverable in deleted tab');
select throws_ok($$select public.place_order('83000000-0000-0000-0000-000000000001','restaurant',current_setting('food.lines')::jsonb)$$,'22023',null,'deleted item cannot be ordered through legacy API');
set local role anon;
select is(public.portal_command(current_setting('food.token'),current_setting('food.guest_request')::uuid,'order',current_setting('food.guest_payload')::jsonb)->>'id',current_setting('food.guest_order'),'guest retry after deletion returns existing order');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select public.order_menu_lifecycle('83000000-0000-0000-0000-000000000001',current_setting('food.item')::uuid,2,gen_random_uuid(),'restore')$$,'owner can restore a deleted item');
select is(public.food_menu_item('83000000-0000-0000-0000-000000000001',current_setting('food.item')::uuid)#>>'{item,active}','false','restored item remains unavailable until reviewed');
reset role;
insert into public.menu_items(tenant_id,property_id,category_id,name,price,dietary_type)select '82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','86000000-0000-0000-0000-000000000001','Vegan bowl '||i,10,'vegan'from generate_series(1,21)i;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(jsonb_array_length(public.food_menu_workspace('83000000-0000-0000-0000-000000000001','{"diet":"veg"}')->'items'),10,'manager renders ten filtered rows');
select is(public.food_menu_workspace('83000000-0000-0000-0000-000000000001','{"diet":"veg"}')->>'total','21','vegetarian filter includes vegan items');
select is(jsonb_array_length(public.food_menu_workspace('83000000-0000-0000-0000-000000000001','{"diet":"veg","page":3}')->'items'),1,'last page contains remaining item');
select is(public.food_menu_workspace('83000000-0000-0000-0000-000000000001','{"diet":"veg","page":999}')->>'page','3','manager clamps out-of-range pages');
select is(public.food_menu_workspace('83000000-0000-0000-0000-000000000001','{"service":"restaurant","diet":"non_veg"}')->>'total','1','service and diet filters combine correctly');
select set_config('food.edit',(current_setting('food.details')::jsonb||'{"variants":[{"id":"8a000000-0000-0000-0000-000000000001","label":"Half","price":"120","version":1},{"id":"8a000000-0000-0000-0000-000000000002","label":"Full","price":"200","version":1}],"active":true}'::jsonb)::text,true);
select lives_ok($$select public.order_menu_save('83000000-0000-0000-0000-000000000001',gen_random_uuid(),current_setting('food.item')::uuid,3,current_setting('food.edit')::jsonb)$$,'restored item sizes can be repriced and activated');
select is(public.food_menu_item('83000000-0000-0000-0000-000000000001',current_setting('food.item')::uuid)#>>'{item,variants,0,price}','120.00','edited portion price persists');
select is((select total from public.orders where id=current_setting('food.order')::uuid),399::numeric,'repricing keeps previously ordered size totals');
select set_config('food.edit2',(public.food_menu_item('83000000-0000-0000-0000-000000000001',current_setting('food.item')::uuid)#>'{item,variants}')::text,true);
select lives_ok($$select public.order_menu_save('83000000-0000-0000-0000-000000000001',gen_random_uuid(),current_setting('food.item')::uuid,4,current_setting('food.details')::jsonb||jsonb_build_object('variants',jsonb_build_array(current_setting('food.edit2')::jsonb->0)))$$,'unused size can be removed without deleting history');
select is((select count(*)::int from public.order_items where order_id=current_setting('food.order')::uuid and variant_label='Full'),1,'removed size remains in old order history');
select ok(not has_table_privilege('authenticated','public.menu_item_variants','update'),'staff cannot bypass versioned size changes');
select ok(not has_table_privilege('authenticated','public.food_menu_photos','insert'),'photo metadata requires authenticated upload handler');
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select throws_ok($$select public.food_menu_workspace('83000000-0000-0000-0000-000000000001')$$,'42501',null,'housekeeping cannot configure menu');
select throws_ok($$select public.food_menu_access('83000000-0000-0000-0000-000000000001')$$,'42501',null,'housekeeping cannot upload menu photos');
select is((select provolatile::text from pg_proc where oid='public.portal_workspace(text,jsonb)'::regprocedure),'v','portal view preserves token last-seen writes under PostgREST');
select *from finish();rollback;
