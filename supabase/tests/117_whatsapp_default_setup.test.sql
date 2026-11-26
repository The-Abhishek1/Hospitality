begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select no_plan();
insert into auth.users(id,email)values('e1000000-0000-0000-0000-000000000001','automation-owner@test.invalid'),('e1000000-0000-0000-0000-000000000002','automation-other@test.invalid');
insert into public.tenants(id,name,slug)values('e2000000-0000-0000-0000-000000000001','Automation A','automation-a'),('e2000000-0000-0000-0000-000000000002','Automation B','automation-b');
insert into public.properties(id,tenant_id,name,property_type)values('e3000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','Hotel A','hotel'),('e3000000-0000-0000-0000-000000000002','e2000000-0000-0000-0000-000000000002','Hotel B','hotel');
insert into public.tenant_memberships(tenant_id,user_id,role)values('e2000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001','owner'),('e2000000-0000-0000-0000-000000000002','e1000000-0000-0000-0000-000000000002','owner');
insert into public.guests(id,tenant_id,full_name,phone)values('e4000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','Asha','+919111111111');
insert into public.whatsapp_connections(id,tenant_id,property_id,phone_number_id,waba_id,display_phone,credentials_ref)values('e6000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','12345678001','12345678002','+919999999999','automation-test');
\set pid e3000000-0000-0000-0000-000000000001
\set tenant e2000000-0000-0000-0000-000000000001
\set guest e4000000-0000-0000-0000-000000000001
\set rid e5000000-0000-0000-0000-000000000001
\set owner e1000000-0000-0000-0000-000000000001

-- Keep the setup consumer isolated from persistent local browser fixtures; rollback restores them.
update public.whatsapp_default_setup set next_check_at=now()+interval '1 day'where property_id<>:'pid';
insert into public.hotel_message_photos(id,property_id,name,url,mime_type)values
('11700000-0000-4000-8000-000000000001',:'pid','Exterior','https://photos.test/1.jpg','image/jpeg'),
('11700000-0000-4000-8000-000000000002',:'pid','Room','https://photos.test/2.jpg','image/jpeg'),
('11700000-0000-4000-8000-000000000003',:'pid','Garden','https://photos.test/3.jpg','image/jpeg'),
('11700000-0000-4000-8000-000000000004',:'pid','Welcome collage','https://photos.test/collage.jpg','image/jpeg');
insert into public.whatsapp_guest_settings(property_id,tenant_id,data)values(:'pid',:'tenant','{"maps_url":"https://maps.example/hotel-a","review_url":"https://review.example/hotel-a","website_url":"https://hotel.example"}');
create temporary table default_fixture(payload jsonb);
\copy default_fixture from 'supabase/tests/fixtures/whatsapp-default-templates.json'
select is((select count(*)::int from public.whatsapp_default_templates where property_id=:'pid'),42,'new WhatsApp connection creates the full per-hotel starter registry');
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select throws_ok(format('select public.claim_whatsapp_default_setup()'),'42501',null,'hotel browser cannot claim provider setup jobs');
reset role;set local role service_role;
select throws_ok(format('select public.save_whatsapp_default_setup(%L,%L,1,''["11700000-0000-4000-8000-000000000001","11700000-0000-4000-8000-000000000002","11700000-0000-4000-8000-000000000003"]'',''https://photos.test/collage.jpg'')',:'pid','e1000000-0000-0000-0000-000000000002'),'42501',null,'another hotel cannot prepare this hotel templates');
select public.save_whatsapp_default_setup(:'pid',:'owner',1,'["11700000-0000-4000-8000-000000000001","11700000-0000-4000-8000-000000000002","11700000-0000-4000-8000-000000000003"]','https://photos.test/collage.jpg');
select public.claim_whatsapp_default_setup()as job\gset
select is((:'job'::jsonb->>'property_id')::uuid,:'pid'::uuid,'setup job is bound to its own hotel');
select is(public.claim_whatsapp_default_setup(),null::jsonb,'setup lease prevents concurrent duplicate creation');
reset role;
select payload into temporary table fixture_copy from default_fixture;
grant select on fixture_copy to service_role;
set local role service_role;
select public.record_whatsapp_default_template(:'pid',(:'job'::jsonb->>'lease')::uuid,'booking_confirmed','116000000000001','https://photos.test/collage.jpg',null);
select public.record_whatsapp_default_template(:'pid',(:'job'::jsonb->>'lease')::uuid,'menu_photos',(select t->>'provider_id'from fixture_copy cross join lateral jsonb_array_elements(payload)t where t->>'name'like'%menu_photos_v1'),'https://photos.test/collage.jpg',null);
select public.sync_whatsapp_provider_templates('e6000000-0000-0000-0000-000000000001','12345678002',(select payload from fixture_copy));
reset role;
select is((select count(*)::int from public.whatsapp_automation_rules where property_id=:'pid'),0,'pending templates do not create owner-paused event rules');
select is((select count(*)::int from public.whatsapp_automation_rules where property_id=:'pid'and enabled),0,'pending templates do not activate');
select is((select jsonb_array_length(data->'categories')from public.whatsapp_guest_menu where property_id=:'pid'),4,'default services are organized into four categories');
select is((select sum(jsonb_array_length(x->'services'))::int from public.whatsapp_guest_menu m cross join lateral jsonb_array_elements(data->'categories')x where property_id=:'pid'),12,'all twelve menu services receive assignments');
select ok(not(select enabled from public.whatsapp_guest_menu where property_id=:'pid'),'pending menu is saved as an unpublished draft');
set local role authenticated;
select public.toggle_whatsapp_defaults(:'pid',2,true);
reset role;set local role service_role;
select public.sync_whatsapp_provider_templates('e6000000-0000-0000-0000-000000000001','12345678002',(select jsonb_agg(x||'{"provider_status":"APPROVED"}'::jsonb)from fixture_copy cross join lateral jsonb_array_elements(payload)x));
reset role;
select is((select count(*)::int from public.whatsapp_automation_rules where property_id=:'pid'and enabled),29,'approved event templates activate automatically after the master switch is on');
select ok(not(select enabled from public.whatsapp_automation_rules where property_id=:'pid'and event_key='review_request'),'separate review reminder stays off to prevent duplicate checkout requests');
select ok((select enabled from public.whatsapp_guest_menu where property_id=:'pid'),'menu publishes automatically when its assigned templates are ready');
select is((select delay_minutes from public.whatsapp_automation_rules where property_id=:'pid'and event_key='arrival_reminder'),180,'arrival reminder is set three hours before hotel check-in');
select is((select delay_minutes from public.whatsapp_automation_rules where property_id=:'pid'and event_key='order_feedback'),20,'food feedback is delayed twenty minutes');
set local role authenticated;
select public.save_whatsapp_automation_rule(:'pid','order_ready',(select version from public.whatsapp_automation_rules where property_id=:'pid'and event_key='order_ready'),false,(select template_id from public.whatsapp_automation_rules where property_id=:'pid'and event_key='order_ready'),(select parameter_keys from public.whatsapp_automation_rules where property_id=:'pid'and event_key='order_ready'),45);
reset role;set local role service_role;
select public.sync_whatsapp_provider_templates('e6000000-0000-0000-0000-000000000001','12345678002',(select jsonb_agg(x||'{"provider_status":"APPROVED"}'::jsonb)from fixture_copy cross join lateral jsonb_array_elements(payload)x));
reset role;
select is((select delay_minutes from public.whatsapp_automation_rules where property_id=:'pid'and event_key='order_ready'),45,'subsequent sync preserves owner-customized event timing');
select ok(not(select enabled from public.whatsapp_automation_rules where property_id=:'pid'and event_key='order_ready'),'subsequent sync preserves an owner-paused event');
select template_id as old_template from public.whatsapp_automation_rules where property_id=:'pid'and event_key='checked_in'\gset
set local role service_role;
select public.register_whatsapp_replacement(:'pid',:'owner',:'old_template','qa_checkin_v2','en_US','Hello {{guest_name}}, your stay at {{hotel_name}} is ready. Thank you for choosing our hotel.');
select public.sync_whatsapp_provider_templates('e6000000-0000-0000-0000-000000000001','12345678002',(select jsonb_agg(x||'{"provider_status":"APPROVED"}'::jsonb)from fixture_copy cross join lateral jsonb_array_elements(payload)x)||jsonb_build_array(jsonb_build_object('provider_id','117999999999999','name','qa_checkin_v2','language','en_US','category','utility','provider_status','PENDING','body','Hello {{guest_name}}, your stay at {{hotel_name}} is ready. Thank you for choosing our hotel.','parameter_names',jsonb_build_array('guest_name','hotel_name'),'supported',true,'service_supported',true,'definition',jsonb_build_object('components',jsonb_build_array(jsonb_build_object('type','BODY','text','Hello {{guest_name}}, your stay at {{hotel_name}} is ready. Thank you for choosing our hotel.'))))));
reset role;
select is((select template_id from public.whatsapp_automation_rules where property_id=:'pid'and event_key='checked_in'),:'old_template'::uuid,'old approved version remains assigned while replacement is pending');
set local role service_role;
select public.sync_whatsapp_provider_templates('e6000000-0000-0000-0000-000000000001','12345678002',(select jsonb_agg(x||'{"provider_status":"APPROVED"}'::jsonb)from fixture_copy cross join lateral jsonb_array_elements(payload)x)||jsonb_build_array(jsonb_build_object('provider_id','117999999999999','name','qa_checkin_v2','language','en_US','category','utility','provider_status','APPROVED','body','Hello {{guest_name}}, your stay at {{hotel_name}} is ready. Thank you for choosing our hotel.','parameter_names',jsonb_build_array('guest_name','hotel_name'),'supported',true,'service_supported',true,'definition',jsonb_build_object('components',jsonb_build_array(jsonb_build_object('type','BODY','text','Hello {{guest_name}}, your stay at {{hotel_name}} is ready. Thank you for choosing our hotel.'))))));
reset role;
select is((select t.name from public.message_templates t join public.whatsapp_automation_rules r on r.template_id=t.id where r.property_id=:'pid'and r.event_key='checked_in'),'qa_checkin_v2','approved replacement switches the event automatically');
select ok(exists(select 1 from public.message_templates where id=:'old_template'and status='approved'),'replacement never deletes the working old template');

select template_id as menu_old from public.whatsapp_default_templates where property_id=:'pid'and slot='menu_food'\gset
set local role service_role;
select public.register_whatsapp_replacement(:'pid',:'owner',:'menu_old','qa_food_menu_v2','en_US','Hello {{guest_name}}, order food securely here: {{portal_url}}. Your hotel will confirm your order in WhatsApp.');
select public.sync_whatsapp_provider_templates('e6000000-0000-0000-0000-000000000001','12345678002',(select jsonb_agg(x||'{"provider_status":"APPROVED"}'::jsonb)from fixture_copy cross join lateral jsonb_array_elements(payload)x)||jsonb_build_array(jsonb_build_object('provider_id','117999999999998','name','qa_food_menu_v2','language','en_US','category','utility','provider_status','APPROVED','body','Hello {{guest_name}}, order food securely here: {{portal_url}}. Your hotel will confirm your order in WhatsApp.','parameter_names',jsonb_build_array('guest_name','portal_url'),'supported',true,'service_supported',true,'definition',jsonb_build_object('components',jsonb_build_array(jsonb_build_object('type','BODY','text','Hello {{guest_name}}, order food securely here: {{portal_url}}. Your hotel will confirm your order in WhatsApp.'))))));
reset role;
select ok(exists(select 1 from public.whatsapp_guest_menu m cross join lateral jsonb_array_elements(data->'categories')k cross join lateral jsonb_array_elements(k->'services')service join public.message_templates t on t.id=(service->>'template_id')::uuid where m.property_id=:'pid'and service->>'native_action'='food'and t.name='qa_food_menu_v2'),'approved replacement updates its menu service automatically');
set local role authenticated;
select public.toggle_whatsapp_defaults(:'pid',3,false);
reset role;
select ok(not(select enabled from public.whatsapp_default_setup where property_id=:'pid'),'master automation can be switched off');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"e1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok(format('select public.whatsapp_default_workspace(%L)',:'pid'),'42501',null,'setup configuration is isolated from other hotels');
reset role;
select *from finish();rollback;
