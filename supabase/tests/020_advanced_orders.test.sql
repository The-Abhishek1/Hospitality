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

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select set_config('test.day',(now()at time zone 'Asia/Kolkata')::date::text,true);
select set_config('test.stay',public.create_reservation('83000000-0000-0000-0000-000000000001','85000000-0000-0000-0000-000000000001','84000000-0000-0000-0000-000000000001',current_setting('test.day')::date,current_setting('test.day')::date+1)::text,true);
select public.check_in_reservation(current_setting('test.stay')::uuid);
select set_config('test.menu',public.order_menu_save('83000000-0000-0000-0000-000000000001','88000000-0000-0000-0000-000000000001',null,null,'{"name":"Mini biscuit","category":"Snacks","price":"0.05","tax":"10","prep_minutes":15,"description":"Fresh biscuit","dietary_notes":"Contains wheat","active":true}')::text,true);
select is(public.order_menu_save('83000000-0000-0000-0000-000000000001','88000000-0000-0000-0000-000000000001',null,null,'{"name":"Mini biscuit","category":"Snacks","price":"0.05","tax":"10","prep_minutes":15,"description":"Fresh biscuit","dietary_notes":"Contains wheat","active":true}')::text,current_setting('test.menu'),'menu retry is idempotent');
select set_config('test.payload',jsonb_build_object('kind','restaurant','items',jsonb_build_array(jsonb_build_object('menu_item_id',current_setting('test.menu'),'quantity',3,'version',1)),'quote','0.17','priority','high','table','Terrace 2','notes','Serve warm')::text,true);
select set_config('test.order',public.orders_create('83000000-0000-0000-0000-000000000001','88000000-0000-0000-0000-000000000002',current_setting('test.payload')::jsonb)::text,true);
select is(public.orders_create('83000000-0000-0000-0000-000000000001','88000000-0000-0000-0000-000000000002',current_setting('test.payload')::jsonb)::text,current_setting('test.order'),'order creation retry returns original order');
select is((select total from public.orders where id=current_setting('test.order')::uuid),0.17::numeric,'tax rounds once per item line with half-cent rounding');
select is((select due_at from public.orders where id=current_setting('test.order')::uuid),now()+interval '15 minutes','longest item preparation target becomes order deadline');
select is((public.order_detail('83000000-0000-0000-0000-000000000001',current_setting('test.order')::uuid)#>>'{order,items,0,name}'),'Mini biscuit','detail shows recorded line name');
select lives_ok($$select public.order_menu_save('83000000-0000-0000-0000-000000000001',gen_random_uuid(),current_setting('test.menu')::uuid,1,'{"name":"Renamed biscuit","category":"Snacks","price":"1.00","tax":"0","active":true}')$$,'menu price and name can change for future orders');
select is((select name_snapshot from public.order_items where order_id=current_setting('test.order')::uuid),'Mini biscuit','menu rename preserves existing order snapshot');
select is((select total from public.orders where id=current_setting('test.order')::uuid),0.17::numeric,'menu price edit preserves recorded order total');
select throws_ok($$select public.orders_create('83000000-0000-0000-0000-000000000001',gen_random_uuid(),current_setting('test.payload')::jsonb)$$,'40001',null,'stale menu version rejects new order');
select throws_ok($$select public.order_action('83000000-0000-0000-0000-000000000001',current_setting('test.order')::uuid,0,gen_random_uuid(),'status','{"status":"preparing"}')$$,'40001',null,'stale order progress is rejected');
select lives_ok($$select public.order_action('83000000-0000-0000-0000-000000000001',current_setting('test.order')::uuid,0,'88000000-0000-0000-0000-000000000003','comment','{"body":"Check terrace delivery"}')$$,'append-only comment survives stale order version');
select lives_ok($$select public.order_action('83000000-0000-0000-0000-000000000001',current_setting('test.order')::uuid,0,'88000000-0000-0000-0000-000000000003','comment','{"body":"Check terrace delivery"}')$$,'internal comment retry is idempotent');
select is(jsonb_array_length(public.order_detail('83000000-0000-0000-0000-000000000001',current_setting('test.order')::uuid)->'comments'),1,'one internal comment recorded');
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok($$select public.order_menu_setup('83000000-0000-0000-0000-000000000001')$$,'42501',null,'front desk cannot configure menu');
select throws_ok($$select public.order_action('83000000-0000-0000-0000-000000000001',current_setting('test.order')::uuid,(select version from public.orders where id=current_setting('test.order')::uuid),gen_random_uuid(),'status','{"status":"preparing"}')$$,'42501',null,'order placement permission does not grant kitchen progress');
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select is(public.order_detail('83000000-0000-0000-0000-000000000001',current_setting('test.order')::uuid)->'payments','[]'::jsonb,'kitchen cannot access payment records');
select is(public.orders_workspace('83000000-0000-0000-0000-000000000001')#>'{stats,unpaid}','null'::jsonb,'kitchen cannot access financial queue counts');
select lives_ok($$select public.order_action('83000000-0000-0000-0000-000000000001',current_setting('test.order')::uuid,(select version from public.orders where id=current_setting('test.order')::uuid),gen_random_uuid(),'status','{"status":"preparing"}')$$,'kitchen starts preparation');
select throws_ok($$select public.order_action('83000000-0000-0000-0000-000000000001',current_setting('test.order')::uuid,(select version from public.orders where id=current_setting('test.order')::uuid),gen_random_uuid(),'status','{"status":"served"}')$$,'22023',null,'kitchen cannot skip ready stage');
select lives_ok($$select public.order_action('83000000-0000-0000-0000-000000000001',current_setting('test.order')::uuid,(select version from public.orders where id=current_setting('test.order')::uuid),gen_random_uuid(),'status','{"status":"ready"}')$$,'kitchen marks ready');
select lives_ok($$select public.order_action('83000000-0000-0000-0000-000000000001',current_setting('test.order')::uuid,(select version from public.orders where id=current_setting('test.order')::uuid),gen_random_uuid(),'status','{"status":"served"}')$$,'kitchen marks served');
select ok((select preparing_at is not null and ready_at is not null and served_at is not null from public.orders where id=current_setting('test.order')::uuid),'progress timestamps are recorded');
select throws_ok($$select public.order_action('83000000-0000-0000-0000-000000000001',current_setting('test.order')::uuid,(select version from public.orders where id=current_setting('test.order')::uuid),gen_random_uuid(),'payment','{"method":"cash","expected_total":"0.17"}')$$,'42501',null,'kitchen cannot record payments');
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select set_config('test.version',(select version::text from public.orders where id=current_setting('test.order')::uuid),true);
select lives_ok($$select public.order_action('83000000-0000-0000-0000-000000000001',current_setting('test.order')::uuid,current_setting('test.version')::integer,'88000000-0000-0000-0000-000000000004','payment','{"method":"cash","reference":"Desk receipt","expected_total":"0.17"}')$$,'billing staff records received payment');
select lives_ok($$select public.order_action('83000000-0000-0000-0000-000000000001',current_setting('test.order')::uuid,current_setting('test.version')::integer,'88000000-0000-0000-0000-000000000004','payment','{"method":"cash","reference":"Desk receipt","expected_total":"0.17"}')$$,'payment retry does not duplicate payment');
select is((select count(*)::int from public.payments where order_id=current_setting('test.order')::uuid),1,'one payment recorded');
select throws_ok($$select public.order_action('83000000-0000-0000-0000-000000000001',current_setting('test.order')::uuid,(select version from public.orders where id=current_setting('test.order')::uuid),gen_random_uuid(),'refund','{}')$$,'42501',null,'front desk cannot refund without finance-write');
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000004","role":"authenticated"}',true);
select is((public.workspace_permissions('83000000-0000-0000-0000-000000000001')->>'orders')::boolean,true,'finance can navigate to its order financial workflow');
select lives_ok($$select public.order_action('83000000-0000-0000-0000-000000000001',current_setting('test.order')::uuid,(select version from public.orders where id=current_setting('test.order')::uuid),gen_random_uuid(),'refund',jsonb_build_object('payment_id',(select id from public.payments where order_id=current_setting('test.order')::uuid),'amount','0.10','expected_refundable','0.17','reason','Item not enjoyed'))$$,'finance records partial refund against original payment');
select is((public.order_detail('83000000-0000-0000-0000-000000000001',current_setting('test.order')::uuid)#>>'{payments,0,refundable}')::numeric,0.07::numeric,'detail exposes remaining refundable amount exactly');
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select set_config('test.room_order',public.orders_create('83000000-0000-0000-0000-000000000001',gen_random_uuid(),jsonb_build_object('kind','room_service','reservation_id',current_setting('test.stay'),'quote','55.00','items',jsonb_build_array(jsonb_build_object('menu_item_id','87000000-0000-0000-0000-000000000001','quantity',1,'version',1))))::text,true);
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select is(public.order_detail('83000000-0000-0000-0000-000000000001',current_setting('test.room_order')::uuid)#>'{order,guest_name}','null'::jsonb,'kitchen gets delivery room without restricted guest profile');
select public.set_order_status(current_setting('test.room_order')::uuid,'preparing');select public.set_order_status(current_setting('test.room_order')::uuid,'ready');select public.set_order_status(current_setting('test.room_order')::uuid,'served');
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is((select count(*)::int from public.folio_items where order_id=current_setting('test.room_order')::uuid),1,'serving room order posts exactly one charge');
select set_config('test.cancel',public.place_order('83000000-0000-0000-0000-000000000001','restaurant','[{"menu_item_id":"87000000-0000-0000-0000-000000000002","quantity":1}]')::text,true);
select throws_ok($$select public.order_action('83000000-0000-0000-0000-000000000001',current_setting('test.cancel')::uuid,(select version from public.orders where id=current_setting('test.cancel')::uuid),gen_random_uuid(),'status','{"status":"cancelled"}')$$,'22023',null,'cancellation requires reason');
select lives_ok($$select public.order_action('83000000-0000-0000-0000-000000000001',current_setting('test.cancel')::uuid,(select version from public.orders where id=current_setting('test.cancel')::uuid),gen_random_uuid(),'status','{"status":"cancelled","reason":"Guest changed mind"}')$$,'cancel records meaningful reason');
select is((select details->>'reason'from public.kitchen_events where order_id=current_setting('test.cancel')::uuid and event_type='cancelled'),'Guest changed mind','cancel reason retained in history');
select throws_ok($$select public.place_order('83000000-0000-0000-0000-000000000001','restaurant','[{"menu_item_id":"87000000-0000-0000-0000-000000000002","quantity":1},{"menu_item_id":"87000000-0000-0000-0000-000000000002","quantity":1}]')$$,'22023',null,'duplicate cart lines are rejected');
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select throws_ok($$select public.orders_workspace('83000000-0000-0000-0000-000000000001')$$,'42501',null,'housekeeping cannot read orders');
select ok(not has_function_privilege('anon','public.orders_create(uuid,uuid,jsonb)','execute'),'anonymous staff ordering RPC revoked');
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select public.order_action('83000000-0000-0000-0000-000000000001',current_setting('test.order')::uuid,(select version from public.orders where id=current_setting('test.order')::uuid),gen_random_uuid(),'refund',jsonb_build_object('payment_id',(select id from public.payments where order_id=current_setting('test.order')::uuid),'amount','0.08','expected_refundable','0.07','reason','Too much'))$$,'22023',null,'refund cannot exceed remaining original payment');
select lives_ok($$select public.order_menu_save('83000000-0000-0000-0000-000000000001',gen_random_uuid(),current_setting('test.menu')::uuid,(select version from public.menu_items where id=current_setting('test.menu')::uuid),'{"name":"Renamed biscuit","category":"Snacks","price":"1.00","tax":"0","active":false}')$$,'menu item can be made unavailable without deleting snapshots');
select is((select count(*)::int from jsonb_array_elements(public.order_setup('83000000-0000-0000-0000-000000000001')->'menu')x where x->>'id'=current_setting('test.menu')),0,'new order setup excludes inactive menu item');
select throws_ok($$select public.place_order('83000000-0000-0000-0000-000000000001','restaurant',jsonb_build_array(jsonb_build_object('menu_item_id',current_setting('test.menu'),'quantity',1)))$$,'22023',null,'legacy ordering also rejects inactive menu item');
select public.place_order('83000000-0000-0000-0000-000000000001','restaurant','[{"menu_item_id":"87000000-0000-0000-0000-000000000002","quantity":1}]',null,'Page table '||i)from generate_series(1,23)i;
select is((public.orders_workspace('83000000-0000-0000-0000-000000000001','{"q":"Page table","page":2}')->>'total')::int,23,'queue counts all matching orders');
select is(jsonb_array_length(public.orders_workspace('83000000-0000-0000-0000-000000000001','{"q":"Page table","page":2}')->'rows'),3,'queue pagination returns remainder beyond first twenty orders');
select is((public.orders_workspace('83000000-0000-0000-0000-000000000001',jsonb_build_object('view','cancelled','q',current_setting('test.cancel')))#>>'{rows,0,payment_state}'),'cancelled','cancelled order never appears as awaiting payment');
select * from finish();rollback;
