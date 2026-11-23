begin;
select plan(29);

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

-- owner: two in-house stays and a portal link for each (tokens kept in session settings for the test)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
do $$ begin
  perform public.create_reservation('a3000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000001','2027-12-01','2027-12-04',1,0,null,'direct','P1');
  perform public.create_reservation('a3000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000001','2027-12-01','2027-12-04',1,0,null,'direct','P2');
  perform public.check_in_reservation((select id from public.reservations where channel_ref='P1'));
  perform public.check_in_reservation((select id from public.reservations where channel_ref='P2'));
  perform set_config('t.tok1', public.create_guest_portal_link((select id from public.reservations where channel_ref='P1')), false);
  perform set_config('t.tok2', public.create_guest_portal_link((select id from public.reservations where channel_ref='P2')), false);
end $$;
select ok(length(current_setting('t.tok1')) = 64, 'link token is 64 hex chars');
select is((select count(*)::int from public.guest_access_tokens where token_hash = current_setting('t.tok1')), 0, 'raw token is never stored');

select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select throws_ok($$select public.create_guest_portal_link((select id from public.reservations limit 1))$$, '42501', null, 'staff without permission cannot mint links');

-- the guest (anon)
reset role; set local role anon;
select is(public.portal_get_stay(current_setting('t.tok1')) -> 'property' ->> 'name', 'Prop 9', 'valid link returns the stay');
select throws_ok($$select public.portal_get_stay('not-a-real-token')$$, '28000', null, 'bad token rejected');
select is_empty($$select 1 from public.reservations$$, 'anon cannot read tables directly');
select lives_ok($$select public.portal_create_request(current_setting('t.tok1'), 'a9000000-0000-0000-0000-000000000001', null, '2 towels')$$, 'guest raises a request');
select is(jsonb_array_length(public.portal_get_stay(current_setting('t.tok1')) -> 'requests'), 1, 'request visible on the stay');
select lives_ok($$select public.portal_place_order(current_setting('t.tok1'), '[{"menu_item_id":"a7000000-0000-0000-0000-000000000001","quantity":1}]'::jsonb)$$, 'guest orders room service');
select throws_ok($$select public.portal_prepare_document(current_setting('t.tok1'), 'id_proof', 'image/jpeg', 1000)$$, '42501', null, 'document prepare is not callable by anon');

-- staff sees the effects
reset role; set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is((select source from public.guest_requests), 'portal', 'request recorded as portal-sourced');
select is((select count(*)::int from public.tasks where guest_request_id is not null), 1, 'routing rule created the linked task');
select is((select total from public.orders), 55.00, 'portal order priced from the menu');
do $$ begin perform public.set_task_status((select id from public.tasks where guest_request_id is not null), 'done'); end $$;

-- feedback scoping
reset role; set local role anon;
select throws_ok($$select public.portal_submit_feedback(current_setting('t.tok2'), ((public.portal_get_stay(current_setting('t.tok1')) -> 'requests' -> 0 ->> 'id'))::uuid, 5)$$, '22023', null, 'cannot rate another stay''s request');
select throws_ok($$select public.portal_submit_feedback(current_setting('t.tok1'), ((public.portal_get_stay(current_setting('t.tok1')) -> 'requests' -> 0 ->> 'id'))::uuid, 6)$$, '23514', null, 'rating must be 1-5');
select lives_ok($$select public.portal_submit_feedback(current_setting('t.tok1'), ((public.portal_get_stay(current_setting('t.tok1')) -> 'requests' -> 0 ->> 'id'))::uuid, 5, 'Fast')$$, 'feedback on own completed request');
select throws_ok($$select public.portal_submit_feedback(current_setting('t.tok1'), ((public.portal_get_stay(current_setting('t.tok1')) -> 'requests' -> 0 ->> 'id'))::uuid, 4)$$, '23505', null, 'one feedback per request');

-- revoke and expiry
reset role; set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$select public.revoke_guest_portal_link((select id from public.guest_access_tokens where token_hash = encode(sha256(convert_to(current_setting('t.tok2'), 'utf8')), 'hex')))$$, 'staff revokes a link');
reset role; set local role anon;
select throws_ok($$select public.portal_get_stay(current_setting('t.tok2'))$$, '28000', null, 'revoked link stops working');
reset role;
update public.guest_access_tokens set expires_at = now() - interval '1 minute' where token_hash = encode(sha256(convert_to(current_setting('t.tok1'), 'utf8')), 'hex');
set local role anon;
select throws_ok($$select public.portal_get_stay(current_setting('t.tok1'))$$, '28000', null, 'expired link stops working');

-- documents (service_role drives prepare / confirm / scan)
reset role;
update public.guest_access_tokens set expires_at = now() + interval '1 day' where token_hash = encode(sha256(convert_to(current_setting('t.tok1'), 'utf8')), 'hex');
set local role service_role;
do $$ begin perform set_config('t.doc', public.portal_prepare_document(current_setting('t.tok1'), 'id_proof', 'image/jpeg', 500000) ->> 'document_id', false); end $$;
select is((select status from public.guest_documents where id = current_setting('t.doc')::uuid), 'pending_upload', 'document row created before upload');
select throws_ok($$select public.portal_prepare_document(current_setting('t.tok1'), 'id_proof', 'application/x-msdownload', 1000)$$, '22023', null, 'executables rejected');
select throws_ok($$select public.portal_prepare_document(current_setting('t.tok1'), 'id_proof', 'image/png', 99999999)$$, '22023', null, 'oversize file rejected');
select lives_ok($$select public.portal_confirm_document(current_setting('t.tok1'), current_setting('t.doc')::uuid)$$, 'upload confirmed');

reset role; set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$select public.authorize_document_access(current_setting('t.doc')::uuid, 'ID check')$$, '22023', null, 'no access before the malware scan passes');
reset role; set local role service_role;
do $$ begin perform public.mark_document_scan(current_setting('t.doc')::uuid, 'clean'); end $$;

reset role; set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$select public.authorize_document_access(current_setting('t.doc')::uuid, 'ID check at arrival')$$, 'staff access authorised once clean');
select is((select count(*)::int from public.document_access_events), 1, 'access is audited');
select lives_ok($$select public.review_document(current_setting('t.doc')::uuid, 'approved')$$, 'document approved');
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select throws_ok($$select public.authorize_document_access(current_setting('t.doc')::uuid, 'curious')$$, '42501', null, 'housekeeper cannot open documents');

select * from finish();
rollback;
