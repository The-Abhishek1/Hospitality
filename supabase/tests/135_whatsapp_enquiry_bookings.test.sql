begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select no_plan();
insert into auth.users(id,email)values('f1000000-0000-0000-0000-000000000001','enquiry-owner@test.invalid'),('f1000000-0000-0000-0000-000000000002','enquiry-other@test.invalid');
insert into public.tenants(id,name,slug)values('f2000000-0000-0000-0000-000000000001','Enquiry A','enquiry-a'),('f2000000-0000-0000-0000-000000000002','Enquiry B','enquiry-b');
insert into public.properties(id,tenant_id,name,property_type)values('f3000000-0000-0000-0000-000000000001','f2000000-0000-0000-0000-000000000001','Enquiry Resort','resort'),('f3000000-0000-0000-0000-000000000002','f2000000-0000-0000-0000-000000000002','Other Hotel','hotel');
insert into public.tenant_memberships(tenant_id,user_id,role)values('f2000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001','owner'),('f2000000-0000-0000-0000-000000000002','f1000000-0000-0000-0000-000000000002','owner');
insert into public.whatsapp_connections(id,tenant_id,property_id,phone_number_id,waba_id,credentials_ref)values('f6000000-0000-0000-0000-000000000001','f2000000-0000-0000-0000-000000000001','f3000000-0000-0000-0000-000000000001','135001','135002','test-enquiries');
insert into public.accommodation_types(id,tenant_id,property_id,name,base_rate,max_occupancy)values('f7000000-0000-0000-0000-000000000001','f2000000-0000-0000-0000-000000000001','f3000000-0000-0000-0000-000000000001','Deluxe',2500,3);
insert into public.accommodation_units(id,tenant_id,property_id,type_id,name)values('f8000000-0000-0000-0000-000000000001','f2000000-0000-0000-0000-000000000001','f3000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000001','D101');
\set pid f3000000-0000-0000-0000-000000000001
\set owner f1000000-0000-0000-0000-000000000001
update public.properties set payment_test_mode=true where id=:'pid';
insert into public.hotel_payment_connections(id,tenant_id,property_id,mode,key_hint,checkout_enabled)values('a1410000-0000-0000-0000-000000000001','f2000000-0000-0000-0000-000000000001',:'pid','test','rzp_test_fixture',true);
insert into private.hotel_payment_credentials values('a1410000-0000-0000-0000-000000000001','v1.fixture');
insert into private.payment_worker_configuration(id,origin,secret_id,enabled)values(true,'https://invalid.example',gen_random_uuid(),true)on conflict(id)do update set enabled=true;
select ((now()at time zone 'Asia/Kolkata')::date+1)::text as arrival,((now()at time zone 'Asia/Kolkata')::date+3)::text as departure \gset
insert into public.room_date_prices(tenant_id,property_id,type_id,night,amount)values('f2000000-0000-0000-0000-000000000001',:'pid','f7000000-0000-0000-0000-000000000001',:'arrival',5500);
set local role service_role;
select public.sync_whatsapp_provider_templates('f6000000-0000-0000-0000-000000000001','135002','[{"provider_id":"1350001","name":"enquiry_booking_welcome","language":"en_US","category":"utility","provider_status":"APPROVED","body":"Hello {{guest_name}}, welcome to {{hotel_name}}. Upload documents at {{portal_url}}. Reply Hi for help.","parameter_names":["guest_name","hotel_name","portal_url"],"supported":true,"service_supported":true,"definition":{"components":[{"type":"BODY"}]}}]');
reset role;
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select public.save_whatsapp_journey(:'pid',0,true,1,true,'photo');
select id as tid from public.message_templates where property_id=:'pid'and name='enquiry_booking_welcome' \gset
select public.save_whatsapp_automation_rule(:'pid','booking_confirmed',0,true,:'tid','["guest_name","hotel_name","portal_url"]',0);
select is((public.whatsapp_booking_workspace(:'pid')->>'enabled')::boolean,true,'WhatsApp booking defaults on alongside the guest journey');
select throws_ok($$select public.save_whatsapp_booking_settings('f3000000-0000-0000-0000-000000000002',0,false)$$,'42501',null,'hotel owners cannot change another hotel’s booking settings');
reset role;
create function pg_temp.incoming(p_phone text,p_body text)returns uuid language plpgsql as $$declare cid uuid;key text:=gen_random_uuid()::text;begin
 cid:=public.ingest_whatsapp_inbound('135001',key,p_phone,'New Customer',key,case when p_body like 'journey:%'then'interactive'else'text'end,p_body,case when p_body like 'journey:%'then jsonb_build_object('interactive',jsonb_build_object('button_reply',jsonb_build_object('id',p_body,'title','Choose')))else'{}'::jsonb end,now());
 perform public.dispatch_whatsapp_guest_replies(50,'https://hotel.test');return cid;
end $$;
create function pg_temp.pick(p_cid uuid,p_action text)returns text language sql as $$select 'journey:'||id from private.whatsapp_journey_actions where conversation_id=p_cid and action=p_action and consumed_at is null order by created_at desc,id desc limit 1$$;
select pg_temp.incoming('919000001351','Hello')as cid \gset
select ok((select body like 'Welcome to Enquiry Resort!%'from public.messages where conversation_id=:'cid'and direction='out'order by created_at desc,id desc limit 1),'unknown customer receives a distinct hotel enquiry welcome');
select ok(private.whatsapp_enquiry(:'cid'),'unbooked chat is an enquiry');
select ok(not(select human_handoff from public.conversations where id=:'cid'),'unknown greeting never pauses automation');
select pg_temp.incoming('919000001351',pg_temp.pick(:'cid','enquiry_start'));
select is((select step from private.whatsapp_booking_sessions where conversation_id=:'cid'),'dates','book button starts one combined date question');
select pg_temp.incoming('919000001351','2026-02-30');
select is((select step from private.whatsapp_booking_sessions where conversation_id=:'cid'),'dates','invalid dates do not advance the booking');
select pg_temp.incoming('919000001351',:'arrival'||' to '||:'arrival');
select is((select step from private.whatsapp_booking_sessions where conversation_id=:'cid'),'dates','same-day departure is rejected');
select pg_temp.incoming('919000001351',:'arrival'||' to '||:'departure');
select pg_temp.incoming('919000001351','2');
select pg_temp.incoming('919000001351','1');
select pg_temp.incoming('919000001351','Maya Rao');
select is((select step from private.whatsapp_booking_sessions where conversation_id=:'cid'),'rooms','name and party lead to live room availability');
select ok(exists(select 1 from public.messages where conversation_id=:'cid'and body like 'Choose your room type.%'and outbound_payload#>>'{interactive,action,sections,0,rows,0,description}'like '%base INR 2500%'),'room choices show availability and indicative base rates');
select pg_temp.pick(:'cid','enquiry_room')as room_choice \gset
select pg_temp.incoming('919000001351',:'room_choice');
select is((select quote from private.whatsapp_booking_sessions where conversation_id=:'cid'),8000::numeric,'full stay quote is stored for explicit confirmation');
select is((select count(*)::integer from public.reservations where property_id=:'pid'),0,'no reservation is created before confirmation');
select pg_temp.pick(:'cid','enquiry_confirm')as confirm_choice \gset
select pg_temp.incoming('919000001352',:'confirm_choice')as other_cid \gset
select is((select count(*)::integer from public.reservations where property_id=:'pid'),0,'another sender cannot use a stolen booking confirmation');
select pg_temp.incoming('919000001351',:'confirm_choice');
select reservation_id as rid from private.whatsapp_booking_sessions where conversation_id=:'cid' \gset

select is((select status from public.reservations where id=:'rid'),'pending_payment','room booking waits for its deposit');
select ok(private.whatsapp_enquiry(:'cid'),'unpaid room hold stays in booking enquiries');
select is((select amount from public.hotel_payment_requests where reservation_id=:'rid'),400000::bigint,'deposit is exactly half of the quoted stay in paise');
select is((select count(*)::integer from public.whatsapp_automation_events where reservation_id=:'rid'and event_key='booking_confirmed'),0,'provisional booking does not send an early welcome');
select id as intent from public.hotel_payment_requests where reservation_id=:'rid' \gset
update public.hotel_payment_requests set lease=gen_random_uuid(),state='creating',creation_started=true where id=:'intent';
select public.apply_online_payment(:'intent',(select lease from public.hotel_payment_requests where id=:'intent'),jsonb_build_object('link',jsonb_build_object('id','plink_Deposit141','reference_id',replace(:'intent','-',''),'amount',400000,'currency','INR','status','paid','order_id','order_Deposit141','short_url','https://rzp.io/deposit141','notes',jsonb_build_object('property_id',:'pid','reservation_id',:'rid')),'payment',jsonb_build_object('id','pay_Deposit141','status','captured','captured',true,'amount',400000,'currency','INR','order_id','order_Deposit141','method','upi')));
select is((select count(*)::integer from public.reservations where property_id=:'pid'),1,'confirmation creates exactly one reservation');
select is((select booking_origin from public.reservations where id=:'rid'),'whatsapp','reservation is labelled as WhatsApp origin');
select is((select status from public.reservations where id=:'rid'),'confirmed','WhatsApp booking is a normal confirmed reservation');
select is((select count(*)::integer from public.unit_holds where reservation_id=:'rid'and active),1,'confirmation reserves an actual unit');
select ok(not private.whatsapp_enquiry(:'cid'),'confirmed conversation moves to Guests');
select ok(exists(select 1 from private.whatsapp_booking_contacts where reservation_id=:'rid'and conversation_id=:'cid'and actor_id is null),'guest confirmation records one-booking contact proof without impersonating staff');
select ok(exists(select 1 from public.whatsapp_automation_events where reservation_id=:'rid'and event_key='booking_confirmed'),'normal booking welcome event is captured');
select is((select count(*)::integer from public.payments where online_request_id=:'intent'),1,'verified deposit is recorded once on the real folio');
select is((select count(*)::integer from public.whatsapp_guest_authorizations where conversation_id=:'cid'),0,'booking does not grant ongoing updates');
select is((select count(*)::integer from public.whatsapp_marketing_permissions where property_id=:'pid'),0,'booking never grants marketing permission');
select pg_temp.incoming('919000001351',:'confirm_choice');
select is((select count(*)::integer from public.reservations where property_id=:'pid'),1,'reused confirmation cannot duplicate the booking');
select is(public.dispatch_whatsapp_automations(50,'https://hotel.test'),1,'existing approved welcome sends after the WhatsApp booking');
select pg_temp.incoming('919000001351','Hi');
select ok(exists(select 1 from private.whatsapp_journey_actions where conversation_id=:'cid'and action='updates'),'after booking Hi enters the existing stay-consent journey');
create function pg_temp.quote(p_phone text,p_in text,p_out text,p_name text)returns uuid language plpgsql as $$declare c uuid;begin
 c:=pg_temp.incoming(p_phone,'BOOK');perform pg_temp.incoming(p_phone,p_in||' to '||p_out);perform pg_temp.incoming(p_phone,'2');perform pg_temp.incoming(p_phone,'1');perform pg_temp.incoming(p_phone,p_name);perform pg_temp.incoming(p_phone,pg_temp.pick(c,'enquiry_room'));return c;
end $$;
select ((now()at time zone 'Asia/Kolkata')::date+10)::text as later_in,((now()at time zone 'Asia/Kolkata')::date+12)::text as later_out \gset
select pg_temp.quote('919000001354',:'later_in',:'later_out','Fresh Quote Guest')as price_cid \gset
select pg_temp.pick(:'price_cid','enquiry_confirm')as stale_quote \gset
update public.accommodation_types set base_rate=3000 where id='f7000000-0000-0000-0000-000000000001';
select pg_temp.incoming('919000001354',:'stale_quote');
select is((select count(*)::integer from public.reservations where property_id=:'pid'),1,'price changes cannot silently book the old quote');
select ok(exists(select 1 from public.messages where conversation_id=:'price_cid'and body like 'The room price changed%'),'guest is asked to review changed pricing');
update public.accommodation_types set base_rate=2500 where id='f7000000-0000-0000-0000-000000000001';
select pg_temp.quote('919000001355',:'later_in',:'later_out','Expired Quote Guest')as expired_cid \gset
update private.whatsapp_booking_sessions set quote_expires_at=now()-interval '1 second'where conversation_id=:'expired_cid';
select pg_temp.incoming('919000001355',pg_temp.pick(:'expired_cid','enquiry_confirm'));
select is((select count(*)::integer from public.reservations where property_id=:'pid'),1,'expired quotes cannot create reservations');
select pg_temp.quote('919000001356',:'later_in',:'later_out','Last Room Winner')as winner_cid \gset
select pg_temp.quote('919000001357',:'later_in',:'later_out','Last Room Other')as loser_cid \gset
select pg_temp.incoming('919000001356',pg_temp.pick(:'winner_cid','enquiry_confirm'));
select pg_temp.incoming('919000001357',pg_temp.pick(:'loser_cid','enquiry_confirm'));
select is((select count(*)::integer from public.reservations where property_id=:'pid'),2,'only one of two quotes can book the last available room');
select ok(not exists(select 1 from public.guests where full_name='Last Room Other'),'failed room allocation rolls back the new guest profile');
select ok(exists(select 1 from public.messages where conversation_id=:'loser_cid'and body like 'No availability%'),'sold-out quote has a recoverable response');
select pg_temp.incoming('919000001357','RECEPTION');
select ok((select human_handoff from public.conversations where id=:'loser_cid'),'explicit reception request pauses the enquiry bot');
select pg_temp.quote('919000001358',((now()at time zone 'Asia/Kolkata')::date+20)::text,((now()at time zone 'Asia/Kolkata')::date+22)::text,'Stopped Guest')as stopped_cid \gset
select pg_temp.pick(:'stopped_cid','enquiry_confirm')as stopped_confirm \gset
select pg_temp.incoming('919000001358','STOP');
select pg_temp.incoming('919000001358',:'stopped_confirm');
select is((select count(*)::integer from public.reservations where property_id=:'pid'),2,'STOP blocks booking confirmation as well as chat replies');
select pg_temp.quote('919000001359',((now()at time zone 'Asia/Kolkata')::date+30)::text,((now()at time zone 'Asia/Kolkata')::date+32)::text,'Restarted Guest')as restart_cid \gset
select pg_temp.pick(:'restart_cid','enquiry_confirm')as old_confirm \gset
select pg_temp.incoming('919000001359','BOOK');
select pg_temp.incoming('919000001359',:'old_confirm');
select is((select step from private.whatsapp_booking_sessions where conversation_id=:'restart_cid'),'dates','old confirmation cannot replace a restarted booking');
select is((select count(*)::integer from public.reservations where property_id=:'pid'),2,'restarted-session buttons never create an unintended booking');
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select is((public.inbox_workspace(:'pid','{"audience":"enquiries"}')->>'total')::integer,7,'enquiry tab retains pending deposits inside pagination');
select is((public.inbox_workspace(:'pid','{"audience":"guests"}')->>'total')::integer,1,'Guests tab includes only the paid confirmed customer');
select is(public.reservation_workspace(:'pid','{"view":"all"}')#>>'{rows,0,booking_origin}','whatsapp','booking origin appears in the staff reservation workspace');
reset role;
insert into public.conversations(tenant_id,property_id,connection_id,wa_contact_id,contact_name)
select 'f2000000-0000-0000-0000-000000000001',:'pid','f6000000-0000-0000-0000-000000000001','919000002'||lpad(n::text,3,'0'),'Extra enquiry '||n from generate_series(1,26)n;
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select is((public.inbox_workspace(:'pid','{"audience":"enquiries","page":2}')->>'total')::integer,33,'enquiry count includes all pages');
select is(jsonb_array_length(public.inbox_workspace(:'pid','{"audience":"enquiries","page":2}')->'conversations'),8,'audience filtering happens before page limits');
select is((public.inbox_workspace(:'pid','{"audience":"guests"}')#>>'{stats,open}')::integer,1,'assignment counters respect the chosen audience');
select set_config('request.jwt.claims',json_build_object('sub','f1000000-0000-0000-0000-000000000002','role','authenticated')::text,true);
select throws_ok(format('select public.inbox_workspace(%L,%L)',:'pid','{"audience":"enquiries"}'),'42501',null,'enquiry tab never exposes another hotel’s contacts');
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select public.save_whatsapp_booking_settings(:'pid',0,false);
reset role;
select pg_temp.incoming('919000001353','Book');
select ok(not exists(select 1 from private.whatsapp_booking_sessions s join public.conversations c on c.id=s.conversation_id where c.wa_contact_id='919000001353'),'disabled hotel booking switch prevents new sessions');
select is(private.inbox_delivery_error((select m.id from public.messages m join public.conversations c on c.id=m.conversation_id where c.wa_contact_id='919000001353'and m.direction='out'order by m.created_at desc,m.id desc limit 1)),null,'reception-only welcome still passes delivery checks when bookings are off');
select ok(not has_function_privilege('authenticated','private.confirm_enquiry_booking(uuid,uuid)','execute'),'guest confirmation has no directly callable browser RPC');
select ok(not has_table_privilege('service_role','private.whatsapp_booking_sessions','select'),'private booking session state is inaccessible to service clients');
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select public.save_whatsapp_booking_settings(:'pid',1,true);
reset role;
select pg_temp.incoming('919000001360','1')as numeric_cid \gset
select ok(exists(select 1 from public.messages where conversation_id=:'numeric_cid'and direction='out'and body like 'Welcome to Enquiry Resort!%'),'unknown numeric greeting receives the enquiry welcome too');

reset role;
select id as expired_rid from public.reservations where property_id=:'pid'and status='pending_payment'limit 1 \gset
select id as expired_intent from public.hotel_payment_requests where reservation_id=:'expired_rid' \gset
update public.reservations set deposit_expires_at=now()-interval '1 second'where id=:'expired_rid';
select is(private.expire_whatsapp_deposits(),1,'the 15-minute unpaid hold expires automatically');
select is((select status from public.reservations where id=:'expired_rid'),'cancelled','expired booking is not left confirmed');
select is((select count(*)::integer from public.unit_holds where reservation_id=:'expired_rid'and active),0,'expiry releases the room for another guest');
update public.hotel_payment_requests set lease=gen_random_uuid()where id=:'expired_intent';
select public.apply_online_payment(:'expired_intent',(select lease from public.hotel_payment_requests where id=:'expired_intent'),jsonb_build_object('link',jsonb_build_object('id','plink_Late141','reference_id',replace(:'expired_intent','-',''),'amount',(select amount from public.hotel_payment_requests where id=:'expired_intent'),'currency','INR','status','paid','order_id','order_Late141','short_url','https://rzp.io/late141','notes',jsonb_build_object('property_id',:'pid','reservation_id',:'expired_rid')),'payment',jsonb_build_object('id','pay_Late141','status','captured','captured',true,'amount',(select amount from public.hotel_payment_requests where id=:'expired_intent'),'currency','INR','order_id','order_Late141','method','upi')));
select is((select status from public.reservations where id=:'expired_rid'),'cancelled','late payment cannot silently rebook a released room');
select ok((select last_error like 'Payment received after%'from public.hotel_payment_requests where id=:'expired_intent'),'late capture is recorded for staff refund/rebooking review');
select is((select count(*)::integer from public.payments where online_request_id=:'expired_intent'),1,'late captured money remains accounted for');
select pg_temp.quote('919000001361',((now()at time zone 'Asia/Kolkata')::date+40)::text,((now()at time zone 'Asia/Kolkata')::date+42)::text,'Deadline Race Guest')as race_cid \gset
select pg_temp.incoming('919000001361',pg_temp.pick(:'race_cid','enquiry_confirm'));
select reservation_id as race_rid,payment_request_id as race_intent from private.whatsapp_booking_sessions where conversation_id=:'race_cid' \gset
update public.reservations set deposit_expires_at=now()-interval '1 second'where id=:'race_rid';
update public.hotel_payment_requests set lease=gen_random_uuid()where id=:'race_intent';
select public.apply_online_payment(:'race_intent',(select lease from public.hotel_payment_requests where id=:'race_intent'),jsonb_build_object('link',jsonb_build_object('id','plink_Race146','reference_id',replace(:'race_intent','-',''),'amount',(select amount from public.hotel_payment_requests where id=:'race_intent'),'currency','INR','status','paid','order_id','order_Race146','short_url','https://rzp.io/race146','notes',jsonb_build_object('property_id',:'pid','reservation_id',:'race_rid')),'payment',jsonb_build_object('id','pay_Race146','status','captured','captured',true,'amount',(select amount from public.hotel_payment_requests where id=:'race_intent'),'currency','INR','order_id','order_Race146','method','upi')));
select is((select status from public.reservations where id=:'race_rid'),'cancelled','late capture before the expiry job also cancels the provisional booking');
select is((select count(*)::integer from public.unit_holds where reservation_id=:'race_rid'and active),0,'the payment finalizer releases the room without waiting for cron');
select is((select count(*)::integer from public.payments where online_request_id=:'race_intent'),1,'racing late payment remains accounted for once');
select is((select count(*)::integer from public.whatsapp_automation_events where reservation_id=:'race_rid'and event_key='booking_confirmed'),0,'late capture cannot emit a false booking confirmation');
select *from finish();
rollback;
