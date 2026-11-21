begin;
select plan(32);

insert into auth.users (id, email) values
  ('c1000000-0000-0000-0000-000000000001', 'owner@t11.test'), ('c1000000-0000-0000-0000-000000000002', 'hk@t11.test');
insert into public.tenants (id, name, slug) values ('c2000000-0000-0000-0000-000000000001', 'Tenant 11', 'tenant-11');
insert into public.properties (id, tenant_id, name, property_type) values
  ('c3000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000001', 'Prop 11', 'hotel'),
  ('c3000000-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000001', 'Prop 11b', 'hotel');
insert into public.tenant_memberships (tenant_id, user_id, role) values
  ('c2000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'owner'),
  ('c2000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000002', 'member');
insert into public.property_memberships (property_id, tenant_id, user_id) values
  ('c3000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000002');
insert into public.user_roles (property_id, user_id, role_id)
select 'c3000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000002', id from public.roles where key = 'housekeeping' and tenant_id is null;
insert into public.accommodation_types (id, tenant_id, property_id, name, max_occupancy, base_rate) values
  ('c4000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-000000000001', 'Std', 2, 100),
  ('c4000000-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-000000000002', 'Other', 2, 100);
insert into public.accommodation_units (tenant_id, property_id, type_id, name) values
  ('c2000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-000000000001', 'c4000000-0000-0000-0000-000000000001', 'D1'),
  ('c2000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-000000000001', 'c4000000-0000-0000-0000-000000000001', 'D2');
insert into public.guests (id, tenant_id, full_name) values ('c5000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000001', 'Direct Guest');


update public.properties set timezone='Asia/Kolkata'where id='c3000000-0000-0000-0000-000000000001';
update public.guests set phone='+919111111111'where id='c5000000-0000-0000-0000-000000000001';
insert into public.guests(id,tenant_id,full_name,phone)values
('c5000000-0000-0000-0000-000000000002','c2000000-0000-0000-0000-000000000001','Same phone','+91 9111-111111'),
('c5000000-0000-0000-0000-000000000003','c2000000-0000-0000-0000-000000000001','No phone',null),
('c5000000-0000-0000-0000-000000000004','c2000000-0000-0000-0000-000000000001','Stopped guest','+919222222222'),
('c5000000-0000-0000-0000-000000000005','c2000000-0000-0000-0000-000000000001','Other hotel guest','+919333333333');
insert into public.reservations(tenant_id,property_id,guest_id,status,check_in,check_out,adults,total_amount,currency)
select 'c2000000-0000-0000-0000-000000000001',case when right(id::text,1)='5'then'c3000000-0000-0000-0000-000000000002'::uuid else'c3000000-0000-0000-0000-000000000001'::uuid end,id,'checked_out','2025-06-01','2025-06-03',1,200,'INR'from public.guests where tenant_id='c2000000-0000-0000-0000-000000000001';
insert into public.message_templates(id,tenant_id,property_id,name,category,status,body)values('c9000000-0000-0000-0000-000000000001','c2000000-0000-0000-0000-000000000001','c3000000-0000-0000-0000-000000000001','summer_offer','marketing','approved','Welcome back! Summer offer.');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
reset role;set local role service_role;
select public.connect_whatsapp('c3000000-0000-0000-0000-000000000001','test-campaign-phone','test-waba','+910000000000','test-credentials');
reset role;set local role authenticated;
select is((public.campaign_audience('c3000000-0000-0000-0000-000000000001','{"from":"2025-05-01","to":"2025-08-31"}')->>'total')::int,3,'audience scopes hotel and deduplicates shared phone');
select is((public.campaign_audience('c3000000-0000-0000-0000-000000000001','{}')->>'eligible')::int,0,'past booking is not marketing permission');
select is((public.campaign_audience('c3000000-0000-0000-0000-000000000001','{"from":"2025-07-01"}')->>'total')::int,0,'stay dates filter historical visitors');
select throws_ok($$select public.record_marketing_permission('c3000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000005','granted','Signed marketing form')$$,'22023',null,'cannot grant permission for another hotel guest');
select public.record_marketing_permission('c3000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000001','granted','Signed marketing form 2025-06-01');
select public.record_marketing_permission('c3000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000004','granted','Signed marketing form');
reset role;set local role service_role;
insert into public.consent_records(tenant_id,property_id,wa_contact_id,status,source)values('c2000000-0000-0000-0000-000000000001','c3000000-0000-0000-0000-000000000001','919222222222','opted_out','keyword');
reset role;set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is((public.campaign_audience('c3000000-0000-0000-0000-000000000001','{}')->>'eligible')::int,1,'STOP overrides marketing permission');
select set_config('test.campaign_data','{"name":"Summer return offer","body":"Welcome back! Summer offer.","filters":{},"selection_mode":"all","selected_guests":[],"template_id":"c9000000-0000-0000-0000-000000000001"}',true);
select set_config('test.campaign',public.save_whatsapp_campaign('c3000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001',null,0,current_setting('test.campaign_data')::jsonb)::text,true);
select is(public.save_whatsapp_campaign('c3000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001',null,0,current_setting('test.campaign_data')::jsonb)::text,current_setting('test.campaign'),'draft save safely replays');
select throws_ok($$select public.launch_whatsapp_campaign('c3000000-0000-0000-0000-000000000001',current_setting('test.campaign')::uuid,1,null)$$,'22023',null,'unverified template cannot launch');
reset role;set local role service_role;
update public.message_templates set campaign_supported=true where id='c9000000-0000-0000-0000-000000000001';
reset role;set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(public.launch_whatsapp_campaign('c3000000-0000-0000-0000-000000000001',current_setting('test.campaign')::uuid,1,to_char((now()+interval '1 day')at time zone'Asia/Kolkata','YYYY-MM-DD"T"HH24:MI')),1,'schedule freezes only eligible phone once');
select is((select schedule_timezone from public.whatsapp_campaigns where id=current_setting('test.campaign')::uuid),'Asia/Kolkata','schedule uses hotel timezone');
select throws_ok($$select public.launch_whatsapp_campaign('c3000000-0000-0000-0000-000000000001',current_setting('test.campaign')::uuid,1,null)$$,'40001',null,'repeated launch cannot duplicate recipients');
reset role;set local role service_role;
select is(public.dispatch_whatsapp_campaigns(),0,'future campaign does not queue early');
reset role;set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select public.record_marketing_permission('c3000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000001','revoked','Guest withdrew permission');
reset role;set local role service_role;
update public.whatsapp_campaigns set scheduled_at=now()-interval '1 second'where id=current_setting('test.campaign')::uuid;
select is(public.dispatch_whatsapp_campaigns(),0,'revocation after scheduling suppresses queueing');
select is((select state from public.whatsapp_campaign_recipients where campaign_id=current_setting('test.campaign')::uuid),'skipped','suppression reason retained');
select public.dispatch_whatsapp_campaigns();
select is((select status from public.whatsapp_campaigns where id=current_setting('test.campaign')::uuid),'completed','dispatch completion includes skipped contacts');
reset role;set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select public.record_marketing_permission('c3000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000001','granted','Guest signed new permission');
select set_config('test.campaign2',public.save_whatsapp_campaign('c3000000-0000-0000-0000-000000000001',gen_random_uuid(),null,0,current_setting('test.campaign_data')::jsonb)::text,true);
select public.launch_whatsapp_campaign('c3000000-0000-0000-0000-000000000001',current_setting('test.campaign2')::uuid,1,null);
reset role;set local role service_role;
select is(public.dispatch_whatsapp_campaigns(),1,'eligible campaign creates one queued message');
select is(public.dispatch_whatsapp_campaigns(),0,'dispatcher does not duplicate queued recipients');
select is((select count(*)::int from public.claim_outbound_messages_v2(10)),0,'legacy workers cannot send campaigns');
select is((select count(*)::int from public.claim_outbound_messages(10)),0,'original v1 worker cannot send campaigns');
select is((select count(*)::int from public.claim_outbound_messages_v3(10,false)),0,'disabled campaign worker cannot claim campaigns');
reset role;set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select public.record_marketing_permission('c3000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000001','revoked','Guest revoked after queue');
reset role;set local role service_role;
select is((select count(*)::int from public.claim_outbound_messages_v3(10,true)),0,'consent rechecked immediately before delivery');
select is((select status from public.messages where campaign_id=current_setting('test.campaign2')::uuid),'failed','ineligible queued message not sent');
reset role;set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is((public.whatsapp_campaign_report('c3000000-0000-0000-0000-000000000001',current_setting('test.campaign2')::uuid)->'audience'->'counts'->>'failed')::int,1,'delivery report distinguishes failed messages');
select public.record_marketing_permission('c3000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000001','granted','Guest renewed permission');
select set_config('test.campaign3',public.save_whatsapp_campaign('c3000000-0000-0000-0000-000000000001',gen_random_uuid(),null,0,current_setting('test.campaign_data')::jsonb)::text,true);
select public.launch_whatsapp_campaign('c3000000-0000-0000-0000-000000000001',current_setting('test.campaign3')::uuid,1,null);
select public.cancel_whatsapp_campaign('c3000000-0000-0000-0000-000000000001',current_setting('test.campaign3')::uuid,2);
reset role;set local role service_role;
select is(public.dispatch_whatsapp_campaigns(),0,'cancelled campaign never dispatches');
select is((select state from public.whatsapp_campaign_recipients where campaign_id=current_setting('test.campaign3')::uuid),'skipped','cancel suppresses pending recipients');
reset role;set local role authenticated;

select set_config('test.campaign4',public.save_whatsapp_campaign('c3000000-0000-0000-0000-000000000001',gen_random_uuid(),null,0,current_setting('test.campaign_data')::jsonb)::text,true);
select public.launch_whatsapp_campaign('c3000000-0000-0000-0000-000000000001',current_setting('test.campaign4')::uuid,1,null);
reset role;set local role service_role;
select public.dispatch_whatsapp_campaigns();
update public.message_templates set status='rejected'where id='c9000000-0000-0000-0000-000000000001';
select is((select count(*)::int from public.claim_outbound_messages_v3(10,true)),0,'template rejection after queue suppresses delivery');
update public.message_templates set status='approved'where id='c9000000-0000-0000-0000-000000000001';
reset role;set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select set_config('test.campaign5',public.save_whatsapp_campaign('c3000000-0000-0000-0000-000000000001',gen_random_uuid(),null,0,current_setting('test.campaign_data')::jsonb)::text,true);
select public.launch_whatsapp_campaign('c3000000-0000-0000-0000-000000000001',current_setting('test.campaign5')::uuid,1,null);
reset role;set local role service_role;
select public.dispatch_whatsapp_campaigns();
update public.whatsapp_connections set phone_number_id='changed-sender'where property_id='c3000000-0000-0000-0000-000000000001';
select is((select count(*)::int from public.claim_outbound_messages_v3(10,true)),0,'sender change after queue suppresses delivery');
select ok((select error like 'Campaign sender%'from public.messages where campaign_id=current_setting('test.campaign5')::uuid),'sender mismatch has explicit failure reason');
reset role;set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select set_config('test.campaign6',public.save_whatsapp_campaign('c3000000-0000-0000-0000-000000000001',gen_random_uuid(),null,0,current_setting('test.campaign_data')::jsonb)::text,true);
select public.launch_whatsapp_campaign('c3000000-0000-0000-0000-000000000001',current_setting('test.campaign6')::uuid,1,null);
reset role;set local role service_role;
select public.dispatch_whatsapp_campaigns();
select is((select count(*)::int from public.claim_outbound_messages_v3(10,true)),1,'enabled worker can claim an eligible campaign');
reset role;set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select public.cancel_whatsapp_campaign('c3000000-0000-0000-0000-000000000001',current_setting('test.campaign6')::uuid,2);
reset role;set local role service_role;
select is((select(public.validate_outbound_claim(id,attempts)->>'ok')::boolean from public.messages where campaign_id=current_setting('test.campaign6')::uuid),false,'cancel after claim is caught before HTTP delivery');
reset role;set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select is_empty($$select 1 from public.whatsapp_campaigns where property_id='c3000000-0000-0000-0000-000000000001'$$,'housekeeping cannot read campaigns');
select throws_ok($$select public.campaign_audience('c3000000-0000-0000-0000-000000000001','{}')$$,'42501',null,'housekeeping cannot read marketing audience');
select throws_ok($$select public.dispatch_whatsapp_campaigns()$$,'42501',null,'staff cannot dispatch campaigns directly');
select *from finish();rollback;
