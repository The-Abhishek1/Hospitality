begin;
select no_plan();

insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'owner@t9.test'), ('a1000000-0000-0000-0000-000000000002', 'hk@t9.test');
insert into public.tenants (id, name, slug) values ('a2000000-0000-0000-0000-000000000001', 'Tenant 9', 'tenant-9');
insert into public.properties (id, tenant_id, name, property_type) values
  ('a3000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', 'Prop 9', 'hotel');
-- This regression covers the existing antivirus route. Photo review has separate coverage.
insert into public.whatsapp_journey_settings(property_id,document_review_mode) values('a3000000-0000-0000-0000-000000000001','antivirus');
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

set local role anon;
select is(public.portal_task_workspace(current_setting('t.token1'),'documents')#>>'{document_state,state}','upload','first document task requests identity upload');
select ok(not(public.portal_task_workspace(current_setting('t.token1'),'documents')?'bill'),'document task returns no bill');
select ok(not(public.portal_task_workspace(current_setting('t.token1'),'documents')?'menu'),'document task returns no food catalog');
select ok(not(public.portal_task_workspace(current_setting('t.token1'),'food')?'documents'),'food task returns no identity documents');
select ok(not(public.portal_task_workspace(current_setting('t.token1'),'food')?'bill'),'food task returns no bill');
select ok(not(public.portal_task_workspace(current_setting('t.token1'),'bill')?'menu'),'bill task returns no food menu');
select is(public.portal_task_workspace(current_setting('t.token1'),'bill')#>>'{stay,id}',current_setting('t.r1'),'focused bill remains scoped to the verified stay');
select throws_ok($$select public.portal_task_workspace(current_setting('t.token1'),'admin')$$,'22023',null,'unknown guest task rejected');
select throws_ok($$select public.portal_task_workspace('invalid','documents')$$,'28000',null,'focused page requires a valid guest token');
select throws_ok($$select public.portal_prepare_document(current_setting('t.token1'),'id_proof','image/png',1000)$$,'42501',null,'anonymous browser cannot bypass signed upload endpoint');
set local role service_role;
select set_config('t.doc1',public.portal_prepare_document(current_setting('t.token1'),'id_proof','image/png',1000)->>'document_id',true);
select public.portal_confirm_document(current_setting('t.token1'),current_setting('t.doc1')::uuid);
set local role anon;
select is(public.portal_task_workspace(current_setting('t.token1'),'documents')#>>'{document_state,state}','review','received documents show review state');
select is(public.portal_task_workspace(current_setting('t.token1'),'documents')#>>'{document_state,can_upload}','false','no repeat upload while review is pending');
select is(public.portal_task_workspace(current_setting('t.token2'),'documents')#>>'{document_state,state}','upload','another stay does not inherit completed upload');
set local role service_role;
select throws_ok($$select public.portal_prepare_document(current_setting('t.token1'),'passport','image/png',1000)$$,'22023',null,'upload service refuses duplicate identity documents');
reset role;
insert into public.whatsapp_automation_rules(property_id,tenant_id,event_key,enabled)values('a3000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000001','documents_rejected',true);
update public.guest_documents set status='clean'where id=current_setting('t.doc1')::uuid;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select public.review_document(current_setting('t.doc1')::uuid,'rejected','Synthetic QA document needs replacement.');
set local role anon;
select is(public.portal_task_workspace(current_setting('t.token1'),'documents')#>>'{document_state,state}','replacement','hotel rejection asks for a replacement');
select is(public.portal_task_workspace(current_setting('t.token1'),'documents')#>>'{document_state,can_upload}','true','rejected document reopens upload');
reset role;
select is((select count(*)::integer from public.whatsapp_automation_events where reservation_id=current_setting('t.r1')::uuid and event_key='documents_rejected'),1,'hotel rejection captures one automatic replacement event');
set local role service_role;
select set_config('t.doc2',public.portal_prepare_document(current_setting('t.token1'),'id_proof','image/png',1000)->>'document_id',true);
select public.portal_confirm_document(current_setting('t.token1'),current_setting('t.doc2')::uuid);
select public.mark_document_scan(current_setting('t.doc2')::uuid,'infected');
reset role;
select is((select count(*)::integer from public.whatsapp_automation_events where reservation_id=current_setting('t.r1')::uuid and event_key='documents_rejected'),2,'security-rejected file captures replacement event too');
set local role service_role;
select set_config('t.doc3',public.portal_prepare_document(current_setting('t.token1'),'passport','image/png',1000)->>'document_id',true);
select public.portal_confirm_document(current_setting('t.token1'),current_setting('t.doc3')::uuid);
select public.mark_document_scan(current_setting('t.doc3')::uuid,'clean');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select public.review_document(current_setting('t.doc3')::uuid,'approved','Synthetic QA approval.');
set local role anon;
select is(public.portal_task_workspace(current_setting('t.token1'),'documents')#>>'{document_state,state}','approved','finished document task shows approval');
select is(public.portal_task_workspace(current_setting('t.token1'),'documents')#>>'{document_state,can_upload}','false','approved identity does not request upload again');
set local role service_role;
select throws_ok($$select public.portal_prepare_document(current_setting('t.token1'),'id_proof','image/png',1000)$$,'22023',null,'server blocks repeat upload after approval');
reset role;
update public.guest_access_tokens set revoked_at=now()where token_hash=encode(sha256(convert_to(current_setting('t.token1'),'utf8')),'hex');
set local role anon;
select throws_ok($$select public.portal_task_workspace(current_setting('t.token1'),'bill')$$,'28000',null,'revocation also closes focused task access');
select is((select provolatile::text from pg_proc where oid='public.portal_task_workspace(text,text,jsonb)'::regprocedure),'v','focused workspace supports token access tracking through PostgREST');
select *from finish();rollback;
