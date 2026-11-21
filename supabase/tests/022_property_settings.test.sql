begin;
select no_plan();

insert into auth.users (id, email) values
  ('61000000-0000-0000-0000-000000000001', 'owner@property-settings.test'), ('61000000-0000-0000-0000-000000000002', 'clerk@property-settings.test'),
  ('61000000-0000-0000-0000-000000000003', 'hk1@property-settings.test'),   ('61000000-0000-0000-0000-000000000004', 'hk2@property-settings.test'),
  ('61000000-0000-0000-0000-000000000005', 'nomember@property-settings.test');
insert into public.tenants (id, name, slug) values ('62000000-0000-0000-0000-000000000001', 'Tenant 5', 'advanced-property-settings');
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
select is((public.property_settings_workspace('63000000-0000-0000-0000-000000000001')#>>'{settings,check_in_time}'),'14:00','existing property gets initialized standard arrival time');
select is((public.property_booking_defaults('63000000-0000-0000-0000-000000000001')->>'nights')::integer,1,'booking defaults preserve existing initial stay length');
select set_config('test.pv',(select version::text from public.properties where id='63000000-0000-0000-0000-000000000001'),true);
select set_config('test.sv',(select version::text from public.property_settings where property_id='63000000-0000-0000-0000-000000000001'),true);
select lives_ok($$select public.property_settings_save('63000000-0000-0000-0000-000000000001',current_setting('test.pv')::integer,current_setting('test.sv')::integer,'6a000000-0000-0000-0000-000000000001','guest','{"check_in_time":"15:30","check_out_time":"10:30","arrival_instructions":"Use the garden entrance","stay_information":"Breakfast 07:00–10:00","reason":"Update guest arrival guidance"}')$$,'guest information can be reviewed and saved');
select lives_ok($$select public.property_settings_save('63000000-0000-0000-0000-000000000001',current_setting('test.pv')::integer,current_setting('test.sv')::integer,'6a000000-0000-0000-0000-000000000001','guest','{"check_in_time":"15:30","check_out_time":"10:30","arrival_instructions":"Use the garden entrance","stay_information":"Breakfast 07:00–10:00","reason":"Update guest arrival guidance"}')$$,'settings retry is idempotent despite old versions');
select is((select count(*)::integer from public.property_settings_events where property_id='63000000-0000-0000-0000-000000000001'),1,'one audit event recorded for repeated submission');
select is((public.property_stay_info('63000000-0000-0000-0000-000000000001')->>'arrival_instructions'),'Use the garden entrance','staff stay context uses configured guest information');
select throws_ok($$select public.property_settings_save('63000000-0000-0000-0000-000000000001',current_setting('test.pv')::integer,current_setting('test.sv')::integer,gen_random_uuid(),'guest','{"check_in_time":"16:00","check_out_time":"11:00","reason":"Stale edit"}')$$,'40001',null,'stale configuration cannot overwrite newer settings');
select throws_ok($$select public.property_settings_save('63000000-0000-0000-0000-000000000001',(select version from public.properties where id='63000000-0000-0000-0000-000000000001'),(select version from public.property_settings where property_id='63000000-0000-0000-0000-000000000001'),gen_random_uuid(),'guest','{"check_in_time":"25:30","check_out_time":"11:00","reason":"Bad time"}')$$,'22023',null,'invalid local time rejected');
select throws_ok($$select public.property_settings_save('63000000-0000-0000-0000-000000000001',(select version from public.properties where id='63000000-0000-0000-0000-000000000001'),(select version from public.property_settings where property_id='63000000-0000-0000-0000-000000000001'),gen_random_uuid(),'localization','{"timezone":"Europe/London","currency":"INR","reason":"No confirmation"}')$$,'22023',null,'timezone changes require explicit acknowledgement');
select lives_ok($$select public.property_settings_save('63000000-0000-0000-0000-000000000001',(select version from public.properties where id='63000000-0000-0000-0000-000000000001'),(select version from public.property_settings where property_id='63000000-0000-0000-0000-000000000001'),gen_random_uuid(),'localization','{"timezone":"UTC","currency":"INR","confirm_timezone":true,"reason":"Use UTC for this test hotel"}')$$,'reviewed timezone change applies before operations');
select set_config('test.rate',(gen_random_uuid())::text,true);
insert into public.rate_plans(id,tenant_id,property_id,name,code,adjustment_percent)values(current_setting('test.rate')::uuid,'62000000-0000-0000-0000-000000000001','63000000-0000-0000-0000-000000000001','Flexible','FLEX',10);
select lives_ok($$select public.property_settings_save('63000000-0000-0000-0000-000000000001',(select version from public.properties where id='63000000-0000-0000-0000-000000000001'),(select version from public.property_settings where property_id='63000000-0000-0000-0000-000000000001'),gen_random_uuid(),'operations',jsonb_build_object('booking_nights',3,'booking_adults',2,'default_rate_plan_id',current_setting('test.rate'),'cleaning_target_minutes',45,'cleaning_priority','high','cleaning_checklist',jsonb_build_array('Clean bathroom','Inspect room'),'reason','Set hotel operational defaults'))$$,'operational preferences can be configured');
select is((public.property_booking_defaults('63000000-0000-0000-0000-000000000001')->>'adults')::integer,2,'new booking setup receives configured adult count');
select is((public.property_booking_defaults('63000000-0000-0000-0000-000000000001')->>'nights')::integer,3,'new booking setup receives configured stay length');
select is((public.task_setup('63000000-0000-0000-0000-000000000001')#>>'{cleaning_defaults,priority}'),'high','room-cleaning setup receives configured priority');
select throws_ok($$select public.property_settings_save('63000000-0000-0000-0000-000000000001',(select version from public.properties where id='63000000-0000-0000-0000-000000000001'),(select version from public.property_settings where property_id='63000000-0000-0000-0000-000000000001'),gen_random_uuid(),'operations','{"booking_nights":1,"booking_adults":1,"cleaning_priority":"normal","cleaning_checklist":[""],"reason":"Invalid checklist"}')$$,'22023',null,'empty cleaning steps are rejected atomically');
select set_config('test.stay',public.create_reservation('63000000-0000-0000-0000-000000000001','65000000-0000-0000-0000-000000000001','64000000-0000-0000-0000-000000000001',current_date,current_date+1,1,0)::text,true);
select public.check_in_reservation(current_setting('test.stay')::uuid);
select set_config('test.token',public.create_guest_portal_link(current_setting('test.stay')::uuid,24),true);
select is((public.property_settings_workspace('63000000-0000-0000-0000-000000000001')->>'currency_locked')::boolean,true,'booking locks operating currency');
select throws_ok($$select public.property_settings_save('63000000-0000-0000-0000-000000000001',(select version from public.properties where id='63000000-0000-0000-0000-000000000001'),(select version from public.property_settings where property_id='63000000-0000-0000-0000-000000000001'),gen_random_uuid(),'localization','{"timezone":"UTC","currency":"USD","confirm_currency":true,"reason":"Too late to change currency"}')$$,'22023',null,'currency cannot change after booking even with acknowledgement');
select public.collect_folio_payment(public.post_room_charges(current_setting('test.stay')::uuid),100,'cash');
select public.check_out_reservation(current_setting('test.stay')::uuid);
select set_config('test.task',(select id::text from public.tasks where reservation_id=current_setting('test.stay')::uuid),true);
select is((select priority from public.tasks where id=current_setting('test.task')::uuid),'high','checkout task snapshots cleaning priority');
select is((select due_at from public.tasks where id=current_setting('test.task')::uuid),now()+interval '45 minutes','checkout task snapshots target from creation');
select is((select count(*)::integer from public.task_checklists where task_id=current_setting('test.task')::uuid),2,'checkout task snapshots configured checklist');
select throws_ok($$select public.set_task_status(current_setting('test.task')::uuid,'done')$$,'22023',null,'configured automatic steps must be checked before completion');
select public.property_settings_save('63000000-0000-0000-0000-000000000001',(select version from public.properties where id='63000000-0000-0000-0000-000000000001'),(select version from public.property_settings where property_id='63000000-0000-0000-0000-000000000001'),gen_random_uuid(),'operations','{"booking_nights":1,"booking_adults":1,"cleaning_priority":"normal","cleaning_target_minutes":"","cleaning_checklist":[],"reason":"Use a different template for future work"}');
select is((select priority from public.tasks where id=current_setting('test.task')::uuid),'high','defaults edits leave existing task priority unchanged');
select is((select count(*)::integer from public.task_checklists where task_id=current_setting('test.task')::uuid),2,'defaults edits leave existing checklist unchanged');
select set_config('request.jwt.claims','{"sub":"61000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select throws_ok($$select public.property_settings_workspace('63000000-0000-0000-0000-000000000001')$$,'42501',null,'housekeeping cannot manage private settings');
select is_empty($$select 1 from public.property_settings$$,'private operations settings are not exposed by direct staff table reads');
select is((public.property_stay_info('63000000-0000-0000-0000-000000000001')->>'check_in_time'),'15:30','staff may see safe guest-facing stay context');
reset role;set local role anon;
select is((public.portal_get_stay(current_setting('test.token'))#>>'{property,check_out_time}'),'10:30','guest portal receives standard hotel departure time');
select is((public.portal_get_stay(current_setting('test.token'))#>>'{property,arrival_instructions}'),'Use the garden entrance','guest portal receives configured arrival guidance');
select ok(not(public.portal_get_stay(current_setting('test.token'))->'property'?'cleaning_checklist'),'guest-facing data excludes private operational defaults');
select ok(not has_function_privilege('anon','public.property_settings_save(uuid,integer,integer,uuid,text,jsonb)','execute'),'anonymous configuration updates revoked');
select * from finish();rollback;
