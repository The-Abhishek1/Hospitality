-- Audit every listed event through its real domain hook or scheduler. All writes roll back.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select no_plan();
insert into auth.users(id,email)values('e1000000-0000-0000-0000-000000000001','automation-owner@test.invalid'),('e1000000-0000-0000-0000-000000000002','automation-other@test.invalid');
insert into public.tenants(id,name,slug)values('e2000000-0000-0000-0000-000000000001','Automation A','automation-a'),('e2000000-0000-0000-0000-000000000002','Automation B','automation-b');
insert into public.properties(id,tenant_id,name,property_type)values('e3000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','Hotel A','hotel'),('e3000000-0000-0000-0000-000000000002','e2000000-0000-0000-0000-000000000002','Hotel B','hotel');
insert into public.tenant_memberships(tenant_id,user_id,role)values('e2000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001','owner'),('e2000000-0000-0000-0000-000000000002','e1000000-0000-0000-0000-000000000002','owner');
insert into public.guests(id,tenant_id,full_name,phone)values('e4000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','Asha','+919111111111');
insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency,created_at)values('e5000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','e4000000-0000-0000-0000-000000000001','confirmed',current_date,current_date+2,5000,'INR',now()-interval '1 day');
insert into public.whatsapp_connections(id,tenant_id,property_id,phone_number_id,waba_id,display_phone,credentials_ref)values('e6000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','12345678001','12345678002','+919999999999','automation-test');

set local role service_role;
select public.sync_whatsapp_provider_templates('e6000000-0000-0000-0000-000000000001','12345678002','[
 {"provider_id":"43505","name":"wired_welcome","language":"en_US","category":"utility","provider_status":"APPROVED","body":"Welcome. Upload documents here: {{portal_url}}. Reply Hi for help.","parameter_names":["portal_url"],"supported":true,"definition":{"components":[{"type":"BODY"}]}},
 {"provider_id":"43501","name":"wired_utility","language":"en_US","category":"utility","provider_status":"APPROVED","body":"Your hotel has recorded a stay update. Contact reception for details.","parameter_names":[],"supported":true,"definition":{"components":[{"type":"BODY","text":"Your hotel has recorded a stay update. Contact reception for details."}]}},
 {"provider_id":"43502","name":"wired_marketing","language":"en_US","category":"marketing","provider_status":"APPROVED","body":"Thank you for staying. Contact reception to share your experience.","parameter_names":[],"supported":true,"definition":{"components":[{"type":"BODY","text":"Thank you for staying. Contact reception to share your experience."}]}},
 {"provider_id":"43503","name":"wired_parameter","language":"en_US","category":"utility","provider_status":"APPROVED","body":"Your hotel update: {{1}}. Contact reception for details.","parameter_names":["1"],"supported":true,"definition":{"components":[{"type":"BODY","text":"Your hotel update: {{1}}. Contact reception for details."}]}},
 {"provider_id":"43504","name":"wired_order","language":"en_US","category":"utility","provider_status":"APPROVED","body":"Your order {{order_reference}} is ready. Contact reception for details.","parameter_names":["order_reference"],"supported":true,"definition":{"components":[{"type":"BODY","text":"Your order {{order_reference}} is ready. Contact reception for details."}]}}
]');
reset role;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"e1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok(format('select public.save_whatsapp_automation_rule(%L,%L,0,true,%L,%L,0)',
 'e3000000-0000-0000-0000-000000000001',x->>'key',t.id,case when x->>'key'='booking_confirmed'then'["portal_url"]'else'[]'end),
 'Owner can assign an existing approved template and activate '||(x->>'key'))
from jsonb_array_elements(public.whatsapp_automation_catalog())x
join public.message_templates t on t.property_id='e3000000-0000-0000-0000-000000000001'
 and t.name=case when x->>'key'='review_request'then'wired_marketing'when x->>'key'='booking_confirmed'then'wired_welcome'else'wired_utility'end;
select set_config('test.wire_parameter',(select id::text from public.message_templates where property_id='e3000000-0000-0000-0000-000000000001'and name='wired_parameter'),true);
select set_config('test.wire_order',(select id::text from public.message_templates where property_id='e3000000-0000-0000-0000-000000000001'and name='wired_order'),true);
select throws_ok($$select public.save_whatsapp_automation_rule('e3000000-0000-0000-0000-000000000001','checked_in',1,true,current_setting('test.wire_parameter')::uuid,'["order_reference"]',0)$$,'22023',null,'Check-in cannot activate with an order-only field');
select throws_ok($$select public.save_whatsapp_automation_rule('e3000000-0000-0000-0000-000000000001','order_ready',1,true,current_setting('test.wire_parameter')::uuid,'["invoice_number"]',0)$$,'22023',null,'Dining cannot activate with an invoice-only field');
select throws_ok($$select public.save_whatsapp_automation_rule('e3000000-0000-0000-0000-000000000001','booking_cancelled',1,true,current_setting('test.wire_parameter')::uuid,'["portal_url"]',0)$$,'22023',null,'Cancellation cannot activate with a private stay link');
select throws_ok($$select public.save_whatsapp_automation_rule('e3000000-0000-0000-0000-000000000001','checked_in',1,true,current_setting('test.wire_order')::uuid,'["guest_name"]',0)$$,'22023',null,'Renaming an unavailable named field does not bypass event compatibility');
select throws_ok($$select public.save_whatsapp_automation_rule('e3000000-0000-0000-0000-000000000001','checked_in',1,true,current_setting('test.wire_parameter')::uuid,'[null]',0)$$,'22023',null,'Null variable mapping cannot activate');
reset role;
select is((select count(*)::integer from public.whatsapp_automation_rules where property_id='e3000000-0000-0000-0000-000000000001'and enabled),23,'All 23 catalog events have an active saved template assignment');
-- Actual domain transitions, rather than calling capture_whatsapp_event directly.
insert into public.accommodation_types(id,tenant_id,property_id,name,max_occupancy,base_rate)values('ed000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','Standard',2,100);
insert into public.accommodation_units(id,tenant_id,property_id,type_id,name)values('ee000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','ed000000-0000-0000-0000-000000000001','101');
insert into public.unit_holds(tenant_id,property_id,unit_id,during,kind,reservation_id)values('e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','ee000000-0000-0000-0000-000000000001',daterange(current_date,current_date+2,'[)'),'reservation','e5000000-0000-0000-0000-000000000001');
select ok(exists(select 1 from public.whatsapp_automation_events where property_id='e3000000-0000-0000-0000-000000000001'and event_key='booking_changed'and source_table='unit_holds'),'Room assignment triggers booking change');
insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency,created_at)values
 ('e5000000-0000-0000-0000-000000000002','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','e4000000-0000-0000-0000-000000000001','confirmed',current_date+1,current_date+3,5000,'INR',now()-interval '1 day');
update public.reservations set check_out=check_out+1 where id='e5000000-0000-0000-0000-000000000002';
select ok(exists(select 1 from public.whatsapp_automation_events where property_id='e3000000-0000-0000-0000-000000000001'and event_key='booking_changed'and source_table='reservations'),'Stay date edit triggers booking change');
update public.reservations set status='checked_in',checked_in_at=now()where id='e5000000-0000-0000-0000-000000000002';
update public.reservations set status='checked_in'where id='e5000000-0000-0000-0000-000000000002';
select is((select count(*)::integer from public.whatsapp_automation_events where event_key='checked_in'and reservation_id='e5000000-0000-0000-0000-000000000002'),1,'Repeated status save emits only one check-in');
update public.reservations set status='cancelled'where id='e5000000-0000-0000-0000-000000000001';
insert into public.orders(id,tenant_id,property_id,kind,reservation_id,total)values
 ('e7000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','room_service','e5000000-0000-0000-0000-000000000002',450),
 ('e7000000-0000-0000-0000-000000000002','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','room_service','e5000000-0000-0000-0000-000000000002',250);
update public.orders set status='preparing'where id='e7000000-0000-0000-0000-000000000001';
update public.orders set status='ready'where id='e7000000-0000-0000-0000-000000000001';
update public.orders set status='served'where id='e7000000-0000-0000-0000-000000000001';
update public.orders set status='cancelled'where id='e7000000-0000-0000-0000-000000000002';
insert into public.guest_requests(id,tenant_id,property_id,reservation_id,title,source)values
 ('e8000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','e5000000-0000-0000-0000-000000000002','Towels','portal'),
 ('e8000000-0000-0000-0000-000000000002','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','e5000000-0000-0000-0000-000000000002','Laundry','portal');
update public.guest_requests set status='in_progress'where id='e8000000-0000-0000-0000-000000000001';
insert into public.tasks(id,tenant_id,property_id,title,guest_request_id,reservation_id)values
 ('e9000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','Internal notes should not leak','e8000000-0000-0000-0000-000000000001','e5000000-0000-0000-0000-000000000002');
update public.tasks set status='done'where id='e9000000-0000-0000-0000-000000000001';
update public.guest_requests set status='completed'where id='e8000000-0000-0000-0000-000000000001';
update public.guest_requests set status='cancelled'where id='e8000000-0000-0000-0000-000000000002';
select is((select count(*)::integer from public.whatsapp_automation_events where event_key='request_completed'and property_id='e3000000-0000-0000-0000-000000000001'),1,'Linked task and service completion produce one guest update');
insert into public.guest_documents(id,tenant_id,property_id,reservation_id,guest_id,doc_type,storage_path,mime_type,size_bytes)values
 ('ec000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','e5000000-0000-0000-0000-000000000002','e4000000-0000-0000-0000-000000000001','passport','private/test.pdf','application/pdf',100),
 ('ec000000-0000-0000-0000-000000000002','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','e5000000-0000-0000-0000-000000000002','e4000000-0000-0000-0000-000000000001','passport','private/test2.pdf','application/pdf',100);
update public.guest_documents set status='uploaded'where id in('ec000000-0000-0000-0000-000000000001','ec000000-0000-0000-0000-000000000002');
update public.guest_documents set status='approved'where id='ec000000-0000-0000-0000-000000000001';
update public.guest_documents set status='rejected'where id='ec000000-0000-0000-0000-000000000002';
select set_config('test.wire_folio',(select id::text from public.folios where reservation_id='e5000000-0000-0000-0000-000000000002'),true);
insert into public.payments(id,tenant_id,property_id,folio_id,amount,method)values('eb000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001',current_setting('test.wire_folio')::uuid,500,'cash');
insert into public.refunds(tenant_id,property_id,payment_id,amount,reason)values('e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','eb000000-0000-0000-0000-000000000001',100,'Refund');
insert into public.invoices(tenant_id,property_id,folio_id,number,total,currency)values('e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001',current_setting('test.wire_folio')::uuid,'WIRE-1',400,'INR');
update public.reservations set status='checked_out',checked_out_at=now()where id='e5000000-0000-0000-0000-000000000002';
select ok(exists(select 1 from public.whatsapp_automation_events where property_id='e3000000-0000-0000-0000-000000000001'and event_key=x->>'key'),'Real domain write captures '||(x->>'key'))
from jsonb_array_elements(public.whatsapp_automation_catalog())x where not(x->>'scheduled')::boolean;
-- Three independent stays ensure all scheduled paths run in the same dispatcher invocation.
insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency,checked_out_at)values
 ('e5000000-0000-0000-0000-000000000003','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','e4000000-0000-0000-0000-000000000001','confirmed',current_date+1,current_date+3,5000,'INR',null),
 ('e5000000-0000-0000-0000-000000000004','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','e4000000-0000-0000-0000-000000000001','checked_in',current_date,current_date+1,5000,'INR',null),
 ('e5000000-0000-0000-0000-000000000005','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','e4000000-0000-0000-0000-000000000001','checked_out',current_date-2,current_date,5000,'INR',now());
-- Review is due a day after checkout, so enabling now never backfills an old action.
update public.whatsapp_automation_rules set delay_minutes=1440 where property_id='e3000000-0000-0000-0000-000000000001'and event_key='review_request';
set local role service_role;
select public.dispatch_whatsapp_automations(200,'https://guest.test');
reset role;
select ok(exists(select 1 from public.whatsapp_automation_events where property_id='e3000000-0000-0000-0000-000000000001'and event_key=x->>'key'),'Scheduler captures '||(x->>'key'))
from jsonb_array_elements(public.whatsapp_automation_catalog())x where(x->>'scheduled')::boolean;
select is((select count(distinct event_key)::integer from public.whatsapp_automation_events where property_id='e3000000-0000-0000-0000-000000000001'),23,'Every listed event is wired to a real source or scheduler');
select ok(not exists(select 1 from public.messages where property_id='e3000000-0000-0000-0000-000000000001'),'No guest permission means no queued message, despite active rules');
select ok(not exists(select 1 from public.whatsapp_automation_events where property_id='e3000000-0000-0000-0000-000000000001'and(payload::text like '%private/test%'or payload::text like '%Internal notes%')),'Document paths and private staff notes stay out of template data');
-- Old invalid configurations must remain pausable after validation is tightened.
update public.whatsapp_automation_rules set template_id=current_setting('test.wire_parameter')::uuid,parameter_keys='["order_reference"]'where property_id='e3000000-0000-0000-0000-000000000001'and event_key='checked_in';
set local role authenticated;
select lives_ok($$select public.save_whatsapp_automation_rule('e3000000-0000-0000-0000-000000000001','checked_in',1,false,current_setting('test.wire_parameter')::uuid,'["order_reference"]',0)$$,'Owner can pause a previously saved incompatible rule');
reset role;
select is((select enabled from public.whatsapp_automation_rules where property_id='e3000000-0000-0000-0000-000000000001'and event_key='checked_in'),false,'Pausing preserves the rule without sending');
select *from finish();
rollback;
