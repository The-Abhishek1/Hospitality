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

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"61000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select set_config('test.day',(now()at time zone 'Asia/Kolkata')::date::text,true);
select is((public.inventory_workspace('63000000-0000-0000-0000-000000000001')->>'total')::int,1,'workspace lists existing rooms');
select set_config('test.type',public.inventory_save('63000000-0000-0000-0000-000000000001','69000000-0000-0000-0000-000000000001','types',null,null,'{"name":"Garden suite","kind":"suite","capacity":4,"base_rate":"150.25","description":"Garden view"}')::text,true);
select is(public.inventory_save('63000000-0000-0000-0000-000000000001','69000000-0000-0000-0000-000000000001','types',null,null,'{"name":"Garden suite","kind":"suite","capacity":4,"base_rate":"150.25","description":"Garden view"}')::text,current_setting('test.type'),'type creation retry returns original record');
select set_config('test.room',public.inventory_save('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'rooms',null,null,jsonb_build_object('name','G201','type_id',current_setting('test.type'),'floor','Garden wing','notes','Private access','active',true))::text,true);
select is((select housekeeping_status from public.accommodation_units where id=current_setting('test.room')::uuid),'dirty','new room requires cleaning before check-in');
select is((public.inventory_detail('63000000-0000-0000-0000-000000000001','rooms',current_setting('test.room')::uuid)#>>'{item,floor}'),'Garden wing','room detail includes configuration');
select is(jsonb_array_length(public.inventory_detail('63000000-0000-0000-0000-000000000001','rooms',current_setting('test.room')::uuid)->'events'),1,'room creation is audited');
select throws_ok($$select public.inventory_save('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'rooms',current_setting('test.room')::uuid,0,jsonb_build_object('name','Changed','type_id',current_setting('test.type'),'active',true))$$,'40001',null,'stale edits cannot overwrite current configuration');
select set_config('test.rate',public.inventory_save('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'rates',null,null,'{"name":"Early bird","code":"early","adjustment":"-10.00","description":"Staff discount plan"}')::text,true);
select is((select code from public.rate_plans where id=current_setting('test.rate')::uuid),'EARLY','rate codes normalized to uppercase');
select is((public.frontdesk_quote('63000000-0000-0000-0000-000000000001',current_setting('test.type')::uuid,current_setting('test.day')::date+1,current_setting('test.day')::date+3,2,0,current_setting('test.rate')::uuid)->>'total')::numeric,270.45::numeric,'configured rate affects new quotes with exact decimal math');
select throws_ok($$select public.inventory_save('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'rates',null,null,'{"name":"Invalid","code":"BAD","adjustment":"-101"}')$$,'22023',null,'rates cannot create negative quoted prices');
select set_config('test.res',public.create_reservation('63000000-0000-0000-0000-000000000001','65000000-0000-0000-0000-000000000001',current_setting('test.type')::uuid,current_setting('test.day')::date+1,current_setting('test.day')::date+3,4,0)::text,true);
select throws_ok($$select public.inventory_save('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'rooms',current_setting('test.room')::uuid,(select version from public.accommodation_units where id=current_setting('test.room')::uuid),jsonb_build_object('name','G201','type_id',current_setting('test.type'),'active',false))$$,'22023',null,'upcoming reservation protects room from deactivation');
select throws_ok($$select public.inventory_save('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'rooms',current_setting('test.room')::uuid,(select version from public.accommodation_units where id=current_setting('test.room')::uuid),'{"name":"G201","type_id":"64000000-0000-0000-0000-000000000001","active":true}')$$,'22023',null,'room type cannot change beneath upcoming booking');
select throws_ok($$select public.inventory_save('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'types',current_setting('test.type')::uuid,(select version from public.accommodation_types where id=current_setting('test.type')::uuid),'{"name":"Garden suite","kind":"suite","capacity":2,"base_rate":"150.25"}')$$,'22023',null,'capacity reduction respects booked guests');
select lives_ok($$select public.inventory_save('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'types',current_setting('test.type')::uuid,(select version from public.accommodation_types where id=current_setting('test.type')::uuid),'{"name":"Garden suite","kind":"suite","capacity":4,"base_rate":"200.00"}')$$,'base price can change for future quotes');
select is((select total_amount from public.reservations where id=current_setting('test.res')::uuid),300.50::numeric,'price edits preserve booked totals');
select throws_ok($$select public.inventory_save('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'blocks',null,null,jsonb_build_object('unit_id',current_setting('test.room'),'from',(current_setting('test.day')::date+2)::text,'to',(current_setting('test.day')::date+4)::text,'reason','Maintenance'))$$,'23P01',null,'block cannot overlap booking');
select set_config('test.blockpayload',jsonb_build_object('unit_id',current_setting('test.room'),'from',(current_setting('test.day')::date+3)::text,'to',(current_setting('test.day')::date+5)::text,'reason','Bathroom maintenance')::text,true);
select set_config('test.block',public.inventory_save('63000000-0000-0000-0000-000000000001','69000000-0000-0000-0000-000000000002','blocks',null,null,current_setting('test.blockpayload')::jsonb)::text,true);
select is(public.inventory_save('63000000-0000-0000-0000-000000000001','69000000-0000-0000-0000-000000000002','blocks',null,null,current_setting('test.blockpayload')::jsonb)::text,current_setting('test.block'),'block creation retry is idempotent');
select is((public.inventory_workspace('63000000-0000-0000-0000-000000000001','{"mode":"blocks","state":"active"}')->>'total')::int,1,'upcoming block appears in active history');
select throws_ok($$select public.inventory_save('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'release',current_setting('test.block')::uuid,0,'{"reason":"Finished"}')$$,'40001',null,'stale release is rejected');
select set_config('test.version',(select version::text from public.unit_holds where id=current_setting('test.block')::uuid),true);
select lives_ok($$select public.inventory_save('63000000-0000-0000-0000-000000000001','69000000-0000-0000-0000-000000000003','release',current_setting('test.block')::uuid,current_setting('test.version')::integer,'{"reason":"Repairs inspected"}')$$,'block release requires reason and preserves record');
select lives_ok($$select public.inventory_save('63000000-0000-0000-0000-000000000001','69000000-0000-0000-0000-000000000003','release',current_setting('test.block')::uuid,current_setting('test.version')::integer,'{"reason":"Repairs inspected"}')$$,'release retry is idempotent');
select is((select active from public.unit_holds where id=current_setting('test.block')::uuid),false,'released block no longer holds inventory');
select is((select housekeeping_status from public.accommodation_units where id=current_setting('test.room')::uuid),'dirty','release does not mark room clean');
select is((select count(*)::int from public.inventory_events where entity_id=current_setting('test.block')::uuid and action='released'),1,'release reason is audited once');
select throws_ok($$select public.inventory_save('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'release',(select id from public.unit_holds where reservation_id=current_setting('test.res')::uuid),1,'{"reason":"Wrong hold type"}')$$,'22023',null,'block release cannot release guest reservation');
select throws_ok($$select public.inventory_detail('63000000-0000-0000-0000-000000000002','rooms',current_setting('test.room')::uuid)$$,'42501',null,'cross-property inventory access denied');
select set_config('request.jwt.claims','{"sub":"61000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok($$select public.inventory_workspace('63000000-0000-0000-0000-000000000001')$$,'42501',null,'front desk cannot access inventory settings');
select throws_ok($$select public.inventory_save('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'types',null,null,'{"name":"Sneaky","kind":"room","capacity":2,"base_rate":"1"}')$$,'42501',null,'front desk cannot mutate inventory');
select set_config('request.jwt.claims','{"sub":"61000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select public.inventory_save('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'rooms',null,null,jsonb_build_object('name','Page room '||i,'type_id',current_setting('test.type'),'active',true))from generate_series(1,23)i;
select is((public.inventory_workspace('63000000-0000-0000-0000-000000000001','{"q":"Page room","page":2}')->>'total')::int,23,'room count includes all matching inventory');
select is(jsonb_array_length(public.inventory_workspace('63000000-0000-0000-0000-000000000001','{"q":"Page room","page":2}')->'rows'),3,'room pagination returns second-page remainder');
select ok(not has_function_privilege('anon','public.inventory_save(uuid,uuid,text,uuid,integer,jsonb)','execute'),'anonymous inventory mutations revoked');
select set_config('test.free_room',(select id::text from public.accommodation_units where name='Page room 1'),true);
select lives_ok($$select public.inventory_save('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'rooms',current_setting('test.free_room')::uuid,(select version from public.accommodation_units where id=current_setting('test.free_room')::uuid),jsonb_build_object('name','Page room 1','type_id',current_setting('test.type'),'active',false))$$,'room without commitments can be deactivated');
select is((select active from public.accommodation_units where id=current_setting('test.free_room')::uuid),false,'deactivation preserves room record');
select throws_ok($$select public.create_inventory_block(current_setting('test.free_room')::uuid,current_setting('test.day')::date+10,current_setting('test.day')::date+12,'Inactive room')$$,'22023',null,'legacy block API cannot hold inactive room');
select lives_ok($$select public.inventory_save('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'rooms',current_setting('test.free_room')::uuid,(select version from public.accommodation_units where id=current_setting('test.free_room')::uuid),jsonb_build_object('name','Page room 1','type_id',current_setting('test.type'),'active',true))$$,'deactivated room can be reactivated');
select public.create_task('63000000-0000-0000-0000-000000000001','Repair window','maintenance','normal',null,current_setting('test.free_room')::uuid);
select throws_ok($$select public.inventory_save('63000000-0000-0000-0000-000000000001',gen_random_uuid(),'rooms',current_setting('test.free_room')::uuid,(select version from public.accommodation_units where id=current_setting('test.free_room')::uuid),jsonb_build_object('name','Page room 1','type_id',current_setting('test.type'),'active',false))$$,'22023',null,'open room work protects against deactivation');
select throws_ok($$select public.inventory_save('63000000-0000-0000-0000-000000000001','69000000-0000-0000-0000-000000000001','types',null,null,'{"name":"Different submission","kind":"room","capacity":2,"base_rate":"1"}')$$,'22023',null,'idempotency key cannot be reused with different inventory details');
select * from finish();
rollback;
