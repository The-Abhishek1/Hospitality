begin;
select no_plan();

insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'owner@t9.test'), ('a1000000-0000-0000-0000-000000000002', 'hk@t9.test');
insert into public.tenants (id, name, slug) values ('a2000000-0000-0000-0000-000000000001', 'Tenant 9', 'tenant-9');
insert into public.properties (id, tenant_id, name, property_type) values
  ('a3000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', 'Prop 9', 'hotel');
insert into public.tenant_memberships (tenant_id, user_id, role) values
  ('a2000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'owner'),
  ('a2000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000002', 'member');
insert into public.property_memberships (property_id, tenant_id, user_id) values
  ('a3000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000002');
insert into public.user_roles (property_id, user_id, role_id)
select 'a3000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000002', id from public.roles where key = 'housekeeping' and tenant_id is null;
insert into public.accommodation_types (id, tenant_id, property_id, name, max_occupancy, base_rate) values
  ('a4000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-000000000001', 'Std', 2, 100);
insert into public.accommodation_units (tenant_id, property_id, type_id, name) values
  ('a2000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000001', 'U1'),
  ('a2000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000001', 'U2');
insert into public.guests (id, tenant_id, full_name) values ('a5000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', 'Portal Guest');
insert into public.menu_categories (id, tenant_id, property_id, name) values ('a6000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-000000000001', 'Drinks');
insert into public.menu_items (id, tenant_id, property_id, category_id, name, price, tax_rate_percent) values
  ('a7000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-000000000001', 'a6000000-0000-0000-0000-000000000001', 'Tea', 50, 10);
insert into public.service_categories (id, tenant_id, property_id, name) values ('a8000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-000000000001', 'Amenities');
insert into public.service_catalog (id, tenant_id, property_id, category_id, name) values
  ('a9000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-000000000001', 'a8000000-0000-0000-0000-000000000001', 'Extra towels');
insert into public.service_routing_rules (tenant_id, property_id, catalog_id, task_kind) values
  ('a2000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-000000000001', 'a9000000-0000-0000-0000-000000000001', 'housekeeping');

update public.properties set timezone='UTC'where id='a3000000-0000-0000-0000-000000000001';
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select set_config('t.r1',public.create_reservation('a3000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000001',current_date,current_date+2,1,0)::text,true);
select set_config('t.r2',public.create_reservation('a3000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000001',current_date,current_date+2,1,0)::text,true);
select set_config('t.token1',public.create_guest_portal_link(current_setting('t.r1')::uuid),true);
select set_config('t.token2',public.create_guest_portal_link(current_setting('t.r2')::uuid),true);


reset role;
insert into public.whatsapp_connections(tenant_id,property_id,phone_number_id,waba_id,display_phone,credentials_ref)values('a2000000-0000-0000-0000-000000000001','a3000000-0000-0000-0000-000000000001','12345678001','12345678002','+919999999999','photo-test');
set local role authenticated;
select public.save_whatsapp_journey('a3000000-0000-0000-0000-000000000001',0,true,1,true,'photo');
select is(public.whatsapp_journey_workspace('a3000000-0000-0000-0000-000000000001')#>>'{settings,document_review_mode}','photo','hotel selects hosted photo review');
set local role anon;
select ok(not has_function_privilege('anon','public.claim_document_image(uuid,text)','execute'),'guest cannot claim privileged photo processing');
select ok(not has_function_privilege('authenticated','public.complete_document_image(uuid,uuid,text,integer,integer,integer,text)','execute'),'staff cannot forge completed image checks');
select throws_ok($$select *from private.document_image_previews$$,'42501',null,'preview metadata is private');
set local role service_role;
select throws_ok($$select public.portal_prepare_document(current_setting('t.token1'),'id_proof','application/pdf',1000)$$,'22023',null,'PDF disabled in photo mode');
select set_config('t.doc',public.portal_prepare_document(current_setting('t.token1'),'id_proof','image/png',1000)->>'document_id',true);
select public.portal_confirm_document(current_setting('t.token1'),current_setting('t.doc')::uuid);
select throws_ok($$select public.claim_document_image(current_setting('t.doc')::uuid,current_setting('t.token2'))$$,'22023',null,'another stay cannot process this file');
select set_config('t.job',public.claim_document_image(current_setting('t.doc')::uuid,current_setting('t.token1'))::text,true);
select is(public.claim_document_image(current_setting('t.doc')::uuid,current_setting('t.token1'))->>'processing','true','concurrent process does not acquire same upload');
select ok(not public.complete_document_image(current_setting('t.doc')::uuid,gen_random_uuid(),'ready',1000,100,100,repeat('a',64)),'stale lease cannot complete');
select throws_ok($$select public.complete_document_image(current_setting('t.doc')::uuid,(current_setting('t.job')::jsonb->>'lease_id')::uuid,'ready',1000,99999,100,repeat('a',64))$$,'22023',null,'invalid preview metadata rejected');
select throws_ok($$select public.mark_document_scan(current_setting('t.doc')::uuid,'clean')$$,'22023',null,'photo is never labelled antivirus clean');
select is((select count(*)::integer from public.claim_document_scans(5)),0,'antivirus worker does not claim photo jobs');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok($$select public.document_photo_prepare_access(current_setting('t.doc')::uuid,'Identity review reason')$$,'42501',null,'housekeeping cannot prepare private identity files');
select set_config('request.jwt.claims','{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select public.authorize_document_access(current_setting('t.doc')::uuid,'Identity review')$$,'22023',null,'original upload cannot be opened before preparation');
select throws_ok($$select public.review_document(current_setting('t.doc')::uuid,'approved','Test')$$,'22023',null,'unprocessed identity cannot be approved');
select lives_ok($$select public.document_photo_prepare_access(current_setting('t.doc')::uuid,'Identity verification review')$$,'staff preparation requires audited permission');
set local role service_role;
select ok(public.complete_document_image(current_setting('t.doc')::uuid,(current_setting('t.job')::jsonb->>'lease_id')::uuid,'ready',1000,100,100,repeat('a',64)),'trusted processor completes rebuilt preview');
select is(public.claim_document_image(current_setting('t.doc')::uuid,current_setting('t.token1'))->>'status','image_ready','completed processing is idempotent');
reset role;
select is((select status from public.guest_documents where id=current_setting('t.doc')::uuid),'image_ready','new state distinguishes image check from virus scan');
select ok((select scanned_at is null from public.guest_documents where id=current_setting('t.doc')::uuid),'no fake antivirus timestamp');
select ok(private.journey_document_error(current_setting('t.r1')::uuid)is not null,'check-in still waits for human identity approval');
set local role authenticated;
select is(public.authorize_document_access(current_setting('t.doc')::uuid,'Identity verification review'),current_setting('t.job')::jsonb->>'preview_path','reviewer receives only rebuilt JPEG path');
select ok(public.authorize_document_access(current_setting('t.doc')::uuid,'Identity verification review')<>current_setting('t.job')::jsonb->>'storage_path','reviewer never receives original object');
select public.review_document(current_setting('t.doc')::uuid,'rejected','Please upload a clearer identity photo.');
set local role anon;
select is(public.portal_task_workspace(current_setting('t.token1'),'documents')#>>'{document_state,state}','replacement','staff rejection reopens focused upload');
set local role service_role;
select set_config('t.doc2',public.portal_prepare_document(current_setting('t.token1'),'passport','image/jpeg',1000)->>'document_id',true);
select public.portal_confirm_document(current_setting('t.token1'),current_setting('t.doc2')::uuid);
select set_config('t.job2',public.claim_document_image(current_setting('t.doc2')::uuid,current_setting('t.token1'))::text,true);
select ok(public.complete_document_image(current_setting('t.doc2')::uuid,(current_setting('t.job2')::jsonb->>'lease_id')::uuid,'invalid'),'invalid image ends in replacement state');
set local role anon;
select is(public.portal_task_workspace(current_setting('t.token1'),'documents')#>>'{document_state,state}','replacement','decode failure permits replacement');
set local role service_role;
select set_config('t.doc3',public.portal_prepare_document(current_setting('t.token1'),'passport','image/jpeg',1000)->>'document_id',true);
select public.portal_confirm_document(current_setting('t.token1'),current_setting('t.doc3')::uuid);
select set_config('t.job3',public.claim_document_image(current_setting('t.doc3')::uuid,current_setting('t.token1'))::text,true);
select public.complete_document_image(current_setting('t.doc3')::uuid,(current_setting('t.job3')::jsonb->>'lease_id')::uuid,'retry');
select set_config('t.job4',public.claim_document_image(current_setting('t.doc3')::uuid,current_setting('t.token1'))::text,true);
select isnt(current_setting('t.job3')::jsonb->>'preview_path',current_setting('t.job4')::jsonb->>'preview_path','retried lease uses separate object to prevent stale cleanup collisions');
select ok(not public.complete_document_image(current_setting('t.doc3')::uuid,(current_setting('t.job3')::jsonb->>'lease_id')::uuid,'ready',1000,100,100,repeat('a',64)),'old attempt cannot complete newer lease');
select public.complete_document_image(current_setting('t.doc3')::uuid,(current_setting('t.job4')::jsonb->>'lease_id')::uuid,'ready',1000,100,100,repeat('a',64));
set local role authenticated;
select public.review_document(current_setting('t.doc3')::uuid,'approved','Synthetic identity approved after review.');
set local role anon;
select is(public.portal_task_workspace(current_setting('t.token1'),'documents')#>>'{document_state,state}','approved','approved identity completes one-time task');
set local role service_role;
select throws_ok($$select public.portal_prepare_document(current_setting('t.token1'),'passport','image/jpeg',1000)$$,'22023',null,'approved identity does not allow repeated uploads');
reset role;
select is(private.journey_document_error(current_setting('t.r1')::uuid),null,'approved rebuilt identity clears check-in document gate');
select *from finish();rollback;
