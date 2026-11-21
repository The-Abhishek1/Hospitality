begin;
select no_plan();

insert into auth.users (id, email) values
  ('71000000-0000-0000-0000-000000000001', 'owner@advanced-service.test'), ('71000000-0000-0000-0000-000000000002', 'clerk@advanced-service.test'),
  ('71000000-0000-0000-0000-000000000003', 'hk1@advanced-service.test'),   ('71000000-0000-0000-0000-000000000004', 'hk2@advanced-service.test');
insert into public.tenants (id, name, slug) values ('72000000-0000-0000-0000-000000000001', 'Tenant 6', 'advanced-services');
insert into public.properties (id, tenant_id, name, property_type) values
  ('73000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', 'Prop 6', 'hotel');
insert into public.tenant_memberships (tenant_id, user_id, role)
select '72000000-0000-0000-0000-000000000001', u, case when u = '71000000-0000-0000-0000-000000000001' then 'owner' else 'member' end
from (values ('71000000-0000-0000-0000-000000000001'::uuid), ('71000000-0000-0000-0000-000000000002'),
             ('71000000-0000-0000-0000-000000000003'), ('71000000-0000-0000-0000-000000000004')) v(u);
insert into public.property_memberships (property_id, tenant_id, user_id)
select '73000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', u
from (values ('71000000-0000-0000-0000-000000000002'::uuid), ('71000000-0000-0000-0000-000000000003'), ('71000000-0000-0000-0000-000000000004')) v(u);
insert into public.user_roles (property_id, user_id, role_id)
select '73000000-0000-0000-0000-000000000001', v.u, r.id
from (values ('71000000-0000-0000-0000-000000000002'::uuid, 'front_desk'), ('71000000-0000-0000-0000-000000000003', 'housekeeping'),
             ('71000000-0000-0000-0000-000000000004', 'housekeeping')) v(u, k)
join public.roles r on r.key = v.k and r.tenant_id is null;
insert into public.accommodation_types (id, tenant_id, property_id, name, max_occupancy, base_rate) values
  ('74000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', '73000000-0000-0000-0000-000000000001', 'Std', 2, 100);
insert into public.accommodation_units (tenant_id, property_id, type_id, name) values
  ('72000000-0000-0000-0000-000000000001', '73000000-0000-0000-0000-000000000001', '74000000-0000-0000-0000-000000000001', 'U1');
insert into public.guests (id, tenant_id, full_name) values ('75000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', 'Guest');
insert into public.service_categories (id, tenant_id, property_id, name) values
  ('76000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', '73000000-0000-0000-0000-000000000001', 'Amenities');
insert into public.service_catalog (id, tenant_id, property_id, category_id, name) values
  ('77000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', '73000000-0000-0000-0000-000000000001', '76000000-0000-0000-0000-000000000001', 'Extra towels'),
  ('77000000-0000-0000-0000-000000000002', '72000000-0000-0000-0000-000000000001', '73000000-0000-0000-0000-000000000001', '76000000-0000-0000-0000-000000000001', 'Late checkout');
insert into public.service_routing_rules (tenant_id, property_id, catalog_id, task_kind, default_assignee_id, sla_minutes) values
  ('72000000-0000-0000-0000-000000000001', '73000000-0000-0000-0000-000000000001', '77000000-0000-0000-0000-000000000001', 'housekeeping', '71000000-0000-0000-0000-000000000003', 30);

-- in-house guest (booked and checked in by the owner)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"71000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
do $$ begin
  perform public.create_reservation('73000000-0000-0000-0000-000000000001','75000000-0000-0000-0000-000000000001','74000000-0000-0000-0000-000000000001','2027-10-01','2027-10-04',1,0,null,'direct','G1');
  perform public.check_in_reservation((select id from public.reservations where channel_ref='G1'));
end $$;

select is(jsonb_array_length(public.service_catalog_setup('73000000-0000-0000-0000-000000000001')->'services'),2,'catalog read model exposes routing configuration');
select is((public.service_request_setup('73000000-0000-0000-0000-000000000001')->>'stay_total')::int,1,'setup lists active stays');
select set_config('test.service',public.service_catalog_save('73000000-0000-0000-0000-000000000001','78000000-0000-0000-0000-000000000001',null,null,'{"name":"Laundry collection","category":"Laundry","description":"Collect at room","priority":"high","target_minutes":45,"kind":"general","assignee":"71000000-0000-0000-0000-000000000003","active":true}')::text,true);
select is(public.service_catalog_save('73000000-0000-0000-0000-000000000001','78000000-0000-0000-0000-000000000001',null,null,'{"name":"Laundry collection","category":"Laundry","description":"Collect at room","priority":"high","target_minutes":45,"kind":"general","assignee":"71000000-0000-0000-0000-000000000003","active":true}')::text,current_setting('test.service'),'catalog retry is idempotent');
select set_config('test.details',jsonb_build_object('reservation_id',(select id from public.reservations where channel_ref='G1'),'catalog_id',current_setting('test.service'),'priority','urgent','target_minutes',15)::text,true);
select set_config('test.request',public.service_desk_create('73000000-0000-0000-0000-000000000001','78000000-0000-0000-0000-000000000002',current_setting('test.details')::jsonb)::text,true);
select is(public.service_desk_create('73000000-0000-0000-0000-000000000001','78000000-0000-0000-0000-000000000002',current_setting('test.details')::jsonb)::text,current_setting('test.request'),'creation retry returns same request');
select is((select count(*)::int from public.tasks where guest_request_id=current_setting('test.request')::uuid),1,'exactly one routed task created');
select ok((select g.priority=t.priority and g.due_at=t.due_at and g.due_at=now()+interval '15 minutes' and t.unit_id is null from public.guest_requests g join public.tasks t on t.guest_request_id=g.id where g.id=current_setting('test.request')::uuid),'request and task share priority and target without affecting room cleanliness');
select is((public.service_request_detail('73000000-0000-0000-0000-000000000001',current_setting('test.request')::uuid)#>>'{request,title}'),'Laundry collection','detail read model supplies service title');
select is((public.service_desk_workspace('73000000-0000-0000-0000-000000000001')->>'total')::int,1,'queue returns scoped request');
select throws_ok($$select public.service_desk_action('73000000-0000-0000-0000-000000000001',current_setting('test.request')::uuid,0,gen_random_uuid(),'triage','{"priority":"low"}')$$,'40001',null,'stale request changes are rejected');
select lives_ok($$select public.service_desk_action('73000000-0000-0000-0000-000000000001',current_setting('test.request')::uuid,0,gen_random_uuid(),'comment','{"body":"Keep this private"}')$$,'append-only comment survives stale task version');
select is(jsonb_array_length(public.service_request_detail('73000000-0000-0000-0000-000000000001',current_setting('test.request')::uuid)->'comments'),1,'internal comment appears in detail');
select set_config('request.jwt.claims','{"sub":"71000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok($$select public.service_catalog_setup('73000000-0000-0000-0000-000000000001')$$,'42501',null,'front desk cannot configure catalog');
select throws_ok($$select public.service_desk_action('73000000-0000-0000-0000-000000000001',current_setting('test.request')::uuid,(select version from public.guest_requests where id=current_setting('test.request')::uuid),gen_random_uuid(),'complete')$$,'42501',null,'front desk cannot bypass linked task permissions');
select lives_ok($$select public.service_desk_action('73000000-0000-0000-0000-000000000001',current_setting('test.request')::uuid,(select version from public.guest_requests where id=current_setting('test.request')::uuid),gen_random_uuid(),'triage','{"priority":"high","deadline":"clear"}')$$,'front desk can triage linked request');
select ok((public.service_request_detail('73000000-0000-0000-0000-000000000001',current_setting('test.request')::uuid)#>>'{request,priority}')='high' and (public.service_request_detail('73000000-0000-0000-0000-000000000001',current_setting('test.request')::uuid)#>'{task,due_at}')='null'::jsonb,'triage synchronizes task priority and removes deadline');
select set_config('request.jwt.claims','{"sub":"71000000-0000-0000-0000-000000000004","role":"authenticated"}',true);
select is((public.service_desk_workspace('73000000-0000-0000-0000-000000000001')->>'total')::int,0,'unrelated housekeeping queue hides requests and counts');
select throws_ok($$select public.service_request_detail('73000000-0000-0000-0000-000000000001',current_setting('test.request')::uuid)$$,'42501',null,'unrelated worker cannot open detail');
select set_config('request.jwt.claims','{"sub":"71000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select is((public.service_desk_workspace('73000000-0000-0000-0000-000000000001')->>'total')::int,1,'assigned worker sees own request');
select lives_ok($$select public.service_desk_action('73000000-0000-0000-0000-000000000001',current_setting('test.request')::uuid,(select version from public.guest_requests where id=current_setting('test.request')::uuid),gen_random_uuid(),'start')$$,'assigned worker starts request via task');
select lives_ok($$select public.service_desk_action('73000000-0000-0000-0000-000000000001',current_setting('test.request')::uuid,(select version from public.guest_requests where id=current_setting('test.request')::uuid),gen_random_uuid(),'complete')$$,'assigned worker completes linked task and request');
select is((select status from public.guest_requests where id=current_setting('test.request')::uuid),'completed','completed task resolves request');
select set_config('request.jwt.claims','{"sub":"71000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select lives_ok($$select public.service_desk_action('73000000-0000-0000-0000-000000000001',current_setting('test.request')::uuid,(select version from public.guest_requests where id=current_setting('test.request')::uuid),gen_random_uuid(),'feedback','{"rating":5,"comment":"Guest said thank you"}')$$,'staff may record reported guest feedback');
select is((select recorded_via from public.guest_request_feedback where guest_request_id=current_setting('test.request')::uuid),'staff_reported','staff feedback provenance is explicit');
select set_config('request.jwt.claims','{"sub":"71000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select is(public.service_request_detail('73000000-0000-0000-0000-000000000001',current_setting('test.request')::uuid)->'feedback','null'::jsonb,'worker does not receive restricted guest feedback');
select set_config('request.jwt.claims','{"sub":"71000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select public.set_task_status((select id from public.tasks where guest_request_id=current_setting('test.request')::uuid),'open')$$,'22023',null,'feedback prevents reopening resolved work');
select set_config('request.jwt.claims','{"sub":"71000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select set_config('test.manual',public.service_desk_create('73000000-0000-0000-0000-000000000001',gen_random_uuid(),jsonb_build_object('reservation_id',(select id from public.reservations where channel_ref='G1'),'title','Wake up call'))::text,true);
select lives_ok($$select public.service_desk_action('73000000-0000-0000-0000-000000000001',current_setting('test.manual')::uuid,(select version from public.guest_requests where id=current_setting('test.manual')::uuid),gen_random_uuid(),'attach_task','{"kind":"general"}')$$,'manager can attach one task to desk request');
select lives_ok($$select public.service_desk_action('73000000-0000-0000-0000-000000000001',current_setting('test.manual')::uuid,(select version from public.guest_requests where id=current_setting('test.manual')::uuid),gen_random_uuid(),'cancel','{"reason":"Guest changed plans"}')$$,'cancellation resolves request and linked task');
select is((select status from public.tasks where guest_request_id=current_setting('test.manual')::uuid),'cancelled','linked task cancellation synchronized');
select throws_ok($$select public.service_catalog_save('73000000-0000-0000-0000-000000000001',gen_random_uuid(),current_setting('test.service')::uuid,0,'{"name":"Laundry","category":"Laundry","priority":"normal","kind":"none","active":false}')$$,'40001',null,'catalog rejects stale edits');
select lives_ok($$select public.service_catalog_save('73000000-0000-0000-0000-000000000001',gen_random_uuid(),current_setting('test.service')::uuid,(select version from public.service_catalog where id=current_setting('test.service')::uuid),'{"name":"Laundry collection","category":"Laundry","priority":"normal","kind":"none","active":false}')$$,'service can be deactivated without deleting history');
select is((select priority from public.guest_requests where id=current_setting('test.request')::uuid),'high','catalog edit leaves existing request priority unchanged');
select throws_ok($$select public.service_desk_create('73000000-0000-0000-0000-000000000001',gen_random_uuid(),current_setting('test.details')::jsonb)$$,'22023',null,'inactive catalog service rejects new requests');
select throws_ok($$select public.service_catalog_save('73000000-0000-0000-0000-000000000001',gen_random_uuid(),null,null,'{"name":"Invalid assignee","category":"Must rollback","priority":"normal","kind":"general","assignee":"71000000-0000-0000-0000-000000000002","active":true}')$$,'22023',null,'routing rejects staff without task-write permission');
select is((select count(*)::int from public.service_categories where name='Must rollback'),0,'invalid configuration leaves no orphan category');
select public.service_desk_create('73000000-0000-0000-0000-000000000001',gen_random_uuid(),jsonb_build_object('reservation_id',(select id from public.reservations where channel_ref='G1'),'title','Paging request '||i)) from generate_series(1,23)i;
select is((public.service_desk_workspace('73000000-0000-0000-0000-000000000001','{"q":"Paging request","page":2}')->>'total')::int,23,'queue counts all matching records');
select is(jsonb_array_length(public.service_desk_workspace('73000000-0000-0000-0000-000000000001','{"q":"Paging request","page":2}')->'rows'),3,'queue second page returns remaining records');
select * from finish();
rollback;
