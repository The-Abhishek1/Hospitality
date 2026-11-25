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

insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values(:'rid',:'tenant',:'pid',:'guest','checked_in',current_date,current_date+2,0,'INR');
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','feedback-start','919111111111','Asha','feedback-start','text','Hi','{}')as cid\gset
reset role;set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select public.save_whatsapp_journey(:'pid',0,true,1,true,'photo');
select public.authorize_whatsapp_stay_updates(:'pid',:'rid',0,'granted','Synthetic verified stay-update agreement for feedback testing.',true);
reset role;
create temporary table feedback_fixture(payload jsonb);
\copy feedback_fixture from 'supabase/tests/fixtures/whatsapp-default-templates.json'
grant select on feedback_fixture to service_role;
set local role service_role;
select public.sync_whatsapp_provider_templates('e6000000-0000-0000-0000-000000000001','12345678002',(select jsonb_agg(x||'{"provider_status":"APPROVED"}'::jsonb)from feedback_fixture cross join lateral jsonb_array_elements(payload)x));
reset role;set local role authenticated;
select public.save_whatsapp_automation_rule(:'pid','order_feedback',0,true,(select id from public.message_templates where property_id=:'pid'and name like'%_order_feedback_v1'),'["guest_name","order_reference","hotel_name"]',20);
select public.save_whatsapp_automation_rule(:'pid','request_feedback',0,true,(select id from public.message_templates where property_id=:'pid'and name like'%_request_feedback_v1'),'["guest_name","hotel_name","request_title"]',5);
reset role;
insert into public.orders(id,tenant_id,property_id,kind,reservation_id,total)values('11800000-0000-4000-8000-000000000001',:'tenant',:'pid','room_service',:'rid',0);
update public.orders set status='preparing'where id='11800000-0000-4000-8000-000000000001';update public.orders set status='ready'where id='11800000-0000-4000-8000-000000000001';update public.orders set status='served'where id='11800000-0000-4000-8000-000000000001';
insert into public.guest_requests(id,tenant_id,property_id,reservation_id,title,source)values('11800000-0000-4000-8000-000000000002',:'tenant',:'pid',:'rid','Fresh towels','portal');
update public.guest_requests set status='completed',completed_at=now()where id='11800000-0000-4000-8000-000000000002';
select is((select count(*)::int from public.whatsapp_automation_events where property_id=:'pid'and event_key in('order_feedback','request_feedback')),2,'delivery and service completion each capture one feedback event');
select ok((select due_at=now()+interval '20 minutes'from public.whatsapp_automation_events where property_id=:'pid'and event_key='order_feedback'),'food request waits twenty minutes after delivery');
select ok((select due_at=now()+interval '5 minutes'from public.whatsapp_automation_events where property_id=:'pid'and event_key='request_feedback'),'service request waits five minutes after completion');
set local role service_role;
select is(public.dispatch_whatsapp_automations(50,'https://guest.test'),0,'feedback requests do not send before their delay');
reset role;
update public.whatsapp_automation_events set due_at=now(),next_check_at=now()where property_id=:'pid';
set local role service_role;
select is(public.dispatch_whatsapp_automations(50,'https://guest.test'),2,'both due approved feedback messages queue with guest permission');
select public.ingest_whatsapp_inbound('12345678001','rate-food','919111111111','Asha','rate-food','text','RATE FOOD','{}');
select public.dispatch_whatsapp_guest_replies(50,'https://guest.test');
reset role;
select 'journey:'||id as target from private.whatsapp_journey_actions where conversation_id=:'cid'and action='feedback_target'and details->>'kind'='food'order by created_at desc limit 1\gset
select private.handle_whatsapp_journey(:'cid',(select id from public.messages where wa_message_id='rate-food'),:'target','https://guest.test');
select 'journey:'||id as score from private.whatsapp_journey_actions where conversation_id=:'cid'and action='feedback_score'and details->>'kind'='food'and details->>'rating'='5'order by created_at desc limit 1\gset
select private.handle_whatsapp_journey(:'cid',(select id from public.messages where wa_message_id='rate-food'),:'score','https://guest.test');
select is((select rating from public.whatsapp_guest_feedback where target_id='11800000-0000-4000-8000-000000000001'),5,'food rating is saved against the exact completed order');
select is(private.whatsapp_automation_error((select id from public.whatsapp_automation_events where property_id=:'pid'and event_key='order_feedback')),'Feedback already received.','a feedback request cannot deliver after feedback is already received');
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','rate-service','919111111111','Asha','rate-service','text','RATE SERVICE','{}');
select public.dispatch_whatsapp_guest_replies(50,'https://guest.test');
reset role;
select 'journey:'||id as target from private.whatsapp_journey_actions where conversation_id=:'cid'and action='feedback_target'and details->>'kind'='service'order by created_at desc limit 1\gset
select private.handle_whatsapp_journey(:'cid',(select id from public.messages where wa_message_id='rate-service'),:'target','https://guest.test');
select 'journey:'||id as score from private.whatsapp_journey_actions where conversation_id=:'cid'and action='feedback_score'and details->>'kind'='service'and details->>'rating'='1'order by created_at desc limit 1\gset
select private.handle_whatsapp_journey(:'cid',(select id from public.messages where wa_message_id='rate-service'),:'score','https://guest.test');
select is((select rating from public.whatsapp_guest_feedback where target_id='11800000-0000-4000-8000-000000000002'),1,'service rating is saved against the exact completed request');
select is((select rating from public.guest_request_feedback where guest_request_id='11800000-0000-4000-8000-000000000002'),1,'WhatsApp service feedback appears in the existing staff request workflow');
select is((select count(*)::int from public.whatsapp_guest_feedback where property_id=:'pid'),2,'one food and one service rating are recorded');
select *from finish();rollback;
