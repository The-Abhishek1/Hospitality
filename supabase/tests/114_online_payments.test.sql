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
\set connection 11400000-0000-4000-8000-000000000001
\set other_connection 11400000-0000-4000-8000-000000000002
\set request 11400000-0000-4000-8000-000000000003
set local role service_role;
select throws_ok(format('select public.payment_connection_commit(%L,%L,%L,''rzp_test_…1234'',''v1.fixture'',false)',:'pid',:'owner',:'connection'),'22023',null,'Test Mode requires a dedicated test hotel declaration');
select throws_ok(format('select public.payment_connection_commit(%L,%L,%L,''rzp_test_…1234'',''v1.fixture'',true)',:'pid','e1000000-0000-0000-0000-000000000002',:'connection'),'42501',null,'another hotel owner cannot connect this hotel');
select public.payment_connection_commit(:'pid',:'owner',:'connection','rzp_test_…1234','v1.fixture',true);
select public.payment_connection_commit('e3000000-0000-0000-0000-000000000002','e1000000-0000-0000-0000-000000000002',:'other_connection','rzp_test_…5678','v1.otherfixture',true);
reset role;
insert into public.accommodation_types(id,tenant_id,property_id,name,max_occupancy,base_rate)values('11400000-0000-4000-8000-000000000010',:'tenant',:'pid','Payment Deluxe',2,500);
insert into public.accommodation_units(id,tenant_id,property_id,type_id,name,housekeeping_status)values('11400000-0000-4000-8000-000000000011',:'tenant',:'pid','11400000-0000-4000-8000-000000000010','PAY101','clean');
insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values(:'rid',:'tenant',:'pid',:'guest','checked_in',current_date,current_date+2,1000,'INR');
insert into public.unit_holds(tenant_id,property_id,unit_id,reservation_id,during,kind)values(:'tenant',:'pid','11400000-0000-4000-8000-000000000011',:'rid',daterange(current_date,current_date+2,'[)'),'reservation');
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','payment-hi','919111111111','Asha','payment-hi','text','Hi','{}')as cid\gset
reset role;set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select throws_ok(format('select public.payment_credential(%L)',:'connection'),'42501',null,'browser cannot read payment credentials');
select throws_ok(format('select public.payment_connection_commit(%L,%L,%L,''rzp_test_…1234'',''v1.fake'',true)',:'pid',:'owner',gen_random_uuid()),'42501',null,'browser cannot forge verified merchant credentials');
select public.payment_connection_action(:'pid',:'connection',1,'enable');
select throws_ok(format('select public.payment_connection_action(%L,%L,1,''pause'')',:'pid',:'connection'),'40001',null,'connection changes are version checked');
select public.save_whatsapp_journey(:'pid',0,true,1,false,'photo');
select public.authorize_whatsapp_stay_updates(:'pid',:'rid',0,'granted','Guest agreed to stay updates and their WhatsApp number was verified.',true);
select public.request_online_payment(:'pid',:'rid',:'request',false)as intent\gset
select is(public.request_online_payment(:'pid',:'rid',:'request',false),:'intent'::uuid,'duplicate request returns the same payment intent');
select is(public.request_online_payment(:'pid',:'rid',gen_random_uuid(),false),:'intent'::uuid,'a stay can have only one open payment link');
select is((select amount from public.hotel_payment_requests where id=:'intent'),100000::bigint,'full booked room charges are posted before calculating paise amount');
select is((select count(*)::int from public.folio_items where property_id=:'pid'and kind='room'),2,'all booked nights appear in the final folio');
select throws_ok(format('select public.collect_folio_payment((select folio_id from public.hotel_payment_requests where id=%L),1000,''cash'',null)',:'intent'),'22023',null,'manual payment cannot double collect while an online link is open');
select throws_ok(format('select public.payment_connection_action(%L,%L,2,''disconnect'')',:'pid',:'connection'),'22023',null,'account cannot be replaced with open links');
reset role;set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','payment-checkout','919111111111','Asha','payment-checkout','text','Checkout','{}');
select is(public.dispatch_whatsapp_guest_replies(50,'https://guest.test'),1,'WhatsApp checkout requests online settlement');
select ok(exists(select 1 from public.messages where conversation_id=:'cid'and journey_purpose='payment_preparing'),'guest receives a preparing-payment response');
select public.claim_online_payment()as job\gset
select (:'job'::jsonb->>'lease')as lease\gset
select is(public.claim_online_payment(),null::jsonb,'in-flight request is not claimed twice');
select throws_ok(format('select public.apply_online_payment(%L,%L,%L)',:'intent',:'lease',jsonb_build_object('link',jsonb_build_object('id','plink_QAPayment','reference_id',replace(:'intent','-',''),'amount',999,'currency','INR','status','created','short_url','https://rzp.io/i/qa','notes',jsonb_build_object('property_id',:'pid','reservation_id',:'rid')))),'22023',null,'wrong provider amount cannot be attached to a bill');
select jsonb_build_object('id','plink_QAPayment','reference_id',replace(:'intent','-',''),'amount',100000,'currency','INR','status','created','order_id','order_QAPayment','short_url','https://rzp.io/i/qa','notes',jsonb_build_object('property_id',:'pid','reservation_id',:'rid'))as link\gset
select is(public.apply_online_payment(:'intent',gen_random_uuid(),jsonb_build_object('link',:'link'::jsonb)),false,'stale completion lease cannot overwrite payment state');
select is(public.apply_online_payment(:'intent',:'lease',jsonb_build_object('link',:'link'::jsonb)),true,'provider link is attached after verification');
reset role;
select is((select state from public.hotel_payment_requests where id=:'intent'),'ready','payment is awaiting the guest');
select ok(exists(select 1 from public.messages where payment_request_id=:'intent'and outbound_payload#>>'{interactive,action,parameters,url}'='https://rzp.io/i/qa'),'payment link is sent inside WhatsApp');
select is(private.reservation_balance(:'rid'),1000::numeric,'a ready link does not mark the bill paid');
set local role service_role;
select is(public.notify_payment_webhook(:'connection','event-paid',repeat('a',64),replace(:'intent','-',''),'plink_QAPayment','order_QAPayment','pay_QAPayment'),true,'signed webhook queues provider reconciliation');
select is(public.notify_payment_webhook(:'connection','event-paid',repeat('a',64),replace(:'intent','-',''),'plink_QAPayment','order_QAPayment','pay_QAPayment'),false,'repeated webhook is deduplicated');
select throws_ok(format('select public.notify_payment_webhook(%L,''event-paid'',%L,null,null,null,null)',:'connection',repeat('b',64)),'22023',null,'same event ID cannot change its signed payload');
select is((select count(*)::int from public.payments where online_request_id=:'intent'),0,'webhook alone does not post money before provider verification');
select public.claim_online_payment()as job\gset
select (:'job'::jsonb->>'lease')as lease\gset
select jsonb_build_object('id','pay_QAPayment','status','captured','captured',true,'amount',100000,'currency','INR','order_id','order_QAPayment','method','upi')as pay\gset
select public.apply_online_payment(:'intent',:'lease',jsonb_build_object('link',jsonb_set(:'link'::jsonb,'{status}','"paid"'),'payment',:'pay'::jsonb,'refunds','[]'::jsonb));
reset role;
select is(private.reservation_balance(:'rid'),0::numeric,'captured payment settles the folio');
select is((select count(*)::int from public.payments where online_request_id=:'intent'),1,'one ledger payment is recorded');
select is((select status from public.reservations where id=:'rid'),'checked_in','payment does not silently check the guest out');
select ok(exists(select 1 from public.messages where payment_request_id=:'intent'and journey_purpose like'online_payment_receipt:%'),'WhatsApp receipt offers a checkout confirmation');
select 'journey:'||id as confirm from private.whatsapp_journey_actions where conversation_id=:'cid'and action='confirm_checkout'order by created_at desc limit 1\gset
set local role service_role;
select public.notify_payment_webhook(:'connection','event-paid-second',repeat('c',64),replace(:'intent','-',''),'plink_QAPayment','order_QAPayment','pay_QAPayment');
select public.claim_online_payment()as job\gset
select throws_ok(format('select public.apply_online_payment(%L,%L,%L)',:'intent',(:'job'::jsonb->>'lease')::uuid,jsonb_build_object('link',:'link'::jsonb)),'22023',null,'an older created status cannot revert a captured payment');
select public.apply_online_payment(:'intent',(:'job'::jsonb->>'lease')::uuid,jsonb_build_object('link',jsonb_set(:'link'::jsonb,'{status}','"paid"'),'payment',:'pay'::jsonb,'refunds','[]'::jsonb));
reset role;
select is((select count(*)::int from public.payments where online_request_id=:'intent'),1,'duplicate provider notifications cannot duplicate ledger money');
select is((select count(*)::int from public.messages where payment_request_id=:'intent'and journey_purpose like'online_payment_receipt:%'),1,'payment receipt is not sent twice');
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','payment-confirm-out','919111111111','Asha','payment-confirm-out','interactive','Confirm checkout',jsonb_build_object('interactive',jsonb_build_object('button_reply',jsonb_build_object('id',:'confirm','title','Confirm checkout'))));
select public.dispatch_whatsapp_guest_replies(50,'https://guest.test');
reset role;
select is((select status from public.reservations where id=:'rid'),'checked_out','guest confirms checkout in WhatsApp after payment');
select is((select housekeeping_status from public.accommodation_units where name='PAY101'and property_id=:'pid'),'dirty','checkout marks the room dirty');
select is((select count(*)::int from public.tasks where reservation_id=:'rid'and kind='housekeeping'),1,'checkout creates one cleaning task');
set local role authenticated;
select throws_ok(format('select public.billing_action(%L,%L,%L,''refund'',jsonb_build_object(''amount'',''100'',''payment_id'',(select id from public.payments where online_request_id=%L),''reason'',''Manual refund''))',:'pid',:'rid',gen_random_uuid(),:'intent'),'22023',null,'manual bookkeeping cannot pretend to issue a Razorpay refund');
reset role;set local role service_role;
select public.notify_payment_webhook(:'connection','event-refund',repeat('d',64),null,null,null,'pay_QAPayment');
select public.claim_online_payment()as job\gset
select public.apply_online_payment(:'intent',(:'job'::jsonb->>'lease')::uuid,jsonb_build_object('link',jsonb_set(:'link'::jsonb,'{status}','"paid"'),'payment',:'pay'::jsonb,'refunds',jsonb_build_array(jsonb_build_object('id','rfnd_QARefund','payment_id','pay_QAPayment','amount',10000,'status','processed'))));
reset role;
select is((select sum(amount)from public.refunds where property_id=:'pid'),100::numeric,'verified gateway refund is recorded automatically');
select is((select count(*)::int from public.refunds where provider_refund_id='rfnd_QARefund'),1,'refund reference is unique');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"e1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select is((select count(*)::int from public.hotel_payment_requests where id=:'intent'),0,'another hotel owner cannot see this payment');
select throws_ok(format('select public.cancel_online_payment(%L,%L)',:'pid',:'intent'),'42501',null,'another hotel cannot cancel this payment');
select throws_ok(format('select public.apply_online_payment(%L,%L,''{}'')',:'intent',gen_random_uuid()),'42501',null,'browser cannot post gateway money');
reset role;
-- Cancellation and uncertain provider outcomes must never permit double collection.
update public.whatsapp_journey_settings set enabled=false where property_id=:'pid';
insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values('11400000-0000-4000-8000-000000000020',:'tenant',:'pid',:'guest','checked_in',current_date,current_date+1,500,'INR');
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select public.request_online_payment(:'pid','11400000-0000-4000-8000-000000000020',gen_random_uuid(),false)as unstarted\gset
select public.cancel_online_payment(:'pid',:'unstarted');
reset role;set local role service_role;
select public.claim_online_payment()as canceljob\gset
select is(:'canceljob'::jsonb->>'operation','cancel','unstarted cancellation claims a cancel operation');
select is((:'canceljob'::jsonb->>'creation_started')::boolean,false,'unstarted cancellation never creates a provider link');
select public.apply_online_payment(:'unstarted',(:'canceljob'::jsonb->>'lease')::uuid,'{"link":null,"cancelled":true}');
select is((select state from public.hotel_payment_requests where id=:'unstarted'),'cancelled','uncreated link is safely cancelled');
reset role;set local role authenticated;
select public.request_online_payment(:'pid','11400000-0000-4000-8000-000000000020',gen_random_uuid(),false)as uncertain\gset
reset role;set local role service_role;
select public.claim_online_payment()as uncertainjob\gset
select public.fail_online_payment(:'uncertain',(:'uncertainjob'::jsonb->>'lease')::uuid,'Synthetic network timeout');
select is((select state from public.hotel_payment_requests where id=:'uncertain'),'unknown','uncertain provider response is not marked failed or paid');
update public.hotel_payment_requests set next_check_at=now(),expires_at=now()-interval '1 hour'where id=:'uncertain';
select public.claim_online_payment()as retryjob\gset
select is(:'retryjob'::jsonb->>'operation','reconcile','timeout retry only reconciles, never creates again');
select public.apply_online_payment(:'uncertain',(:'retryjob'::jsonb->>'lease')::uuid,'{"link":null,"expired":true}');
select is((select state from public.hotel_payment_requests where id=:'uncertain'),'unknown','elapsed clock cannot falsely expire an uncertain creation');
select is((select reconcile_needed from public.hotel_payment_requests where id=:'uncertain'),true,'uncertain outcome stays queued for reconciliation');
reset role;
select throws_ok(format('select public.collect_folio_payment((select folio_id from public.hotel_payment_requests where id=%L),500,''cash'',null)',:'uncertain'),'22023',null,'uncertain creation continues blocking duplicate collection');
set local role authenticated;
select public.cancel_online_payment(:'pid',:'uncertain');
reset role;set local role service_role;
select public.claim_online_payment()as retryjob\gset
select public.apply_online_payment(:'uncertain',(:'retryjob'::jsonb->>'lease')::uuid,'{"link":null,"cancelled":true}');
select is((select state from public.hotel_payment_requests where id=:'uncertain'),'cancel_pending','cancel request stays blocked until provider confirms uncertain creation');
reset role;
update public.hotel_payment_requests set next_check_at=now()+interval '1 hour'where id=:'uncertain';
-- A separate stay allows an expired, never-started request to be tested without releasing the uncertain one.
insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values('11400000-0000-4000-8000-000000000021',:'tenant',:'pid',:'guest','checked_in',current_date,current_date+1,500,'INR');
set local role authenticated;
select public.request_online_payment(:'pid','11400000-0000-4000-8000-000000000021',gen_random_uuid(),false)as elapsed\gset
reset role;
update public.hotel_payment_requests set expires_at=now()-interval '1 minute'where id=:'elapsed';
set local role service_role;
select is(public.claim_online_payment(),null::jsonb,'expired unstarted request never attempts provider creation');
select is((select state from public.hotel_payment_requests where id=:'elapsed'),'expired','unstarted expired intent safely releases its open-link slot');
reset role;
set local role service_role;
select throws_ok(format('select public.payment_connection_commit(%L,%L,%L,''rzp_live_…5678'',''v1.synthetic'',false)',:'pid',:'owner',gen_random_uuid()),'22023','This hotel has recorded payments in the other mode. Use a separate hotel for Test Mode so synthetic and real receipts stay separate.','recorded test receipts cannot be relabelled as live payments');
select lives_ok(format('select public.payment_connection_commit(%L,%L,%L,''rzp_live_…5678'',''v1.synthetic'',false)','e3000000-0000-0000-0000-000000000002','e1000000-0000-0000-0000-000000000002',gen_random_uuid()),'a hotel without payment history can connect its verified live merchant');
reset role;
select *from finish();rollback;
