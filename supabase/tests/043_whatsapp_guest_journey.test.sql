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
set local role service_role;
select public.sync_whatsapp_provider_templates('e6000000-0000-0000-0000-000000000001','12345678002','[{"provider_id":"901","name":"journey_welcome","language":"en_US","category":"utility","provider_status":"APPROVED","body":"Hello {{guest_name}}, welcome to {{hotel_name}}. Upload securely: {{portal_url}}. Reply Hi to choose updates.","parameter_names":["guest_name","hotel_name","portal_url"],"supported":true,"service_supported":true,"definition":{"components":[{"type":"BODY"},{"type":"HEADER","format":"IMAGE"},{"type":"BUTTONS","buttons":[{"type":"URL","url":"https://hotel.test/location","text":"Location"}]}]}}]');
reset role;
insert into public.whatsapp_template_assets values(:'pid','901','https://hotel.test/front.jpg');
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select id as tid from public.message_templates where property_id=:'pid'and name='journey_welcome' \gset
select lives_ok(format('select public.save_whatsapp_journey(%L,0,true,2,true)',:'pid'),'owner enables the WhatsApp-first journey');
select throws_ok(format('select public.save_whatsapp_journey(%L,0,true,2,true)',:'pid'),'40001',null,'configuration is version checked');
select throws_ok($$select public.save_whatsapp_journey('e3000000-0000-0000-0000-000000000002',0,true,1,true)$$,'42501',null,'cannot configure another hotel');
select public.save_whatsapp_automation_rule(:'pid','booking_confirmed',0,true,:'tid','["guest_name","hotel_name","portal_url"]',0);
select public.save_whatsapp_automation_rule(:'pid','documents_approved',0,true,:'tid','["guest_name","hotel_name","portal_url"]',0);
reset role;
insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values(:'rid',:'tenant',:'pid',:'guest','confirmed',current_date,current_date+2,5000,'INR');
select is((select count(*)::integer from public.whatsapp_automation_events where property_id=:'pid'and event_key='booking_confirmed'),1,'new booking automatically captures a welcome');
set local role service_role;
select is(public.dispatch_whatsapp_automations(50,'https://guest.test'),0,'no prior contact permission holds the first welcome');
reset role;
select ok((select reason like '%permission%'from public.whatsapp_automation_events where reservation_id=:'rid'and event_key='booking_confirmed'),'delivery hold explains missing permission');
set local role authenticated;
select public.record_whatsapp_booking_contact(:'pid',:'rid','Guest requested a booking welcome and verified their WhatsApp number at booking.',true);
reset role;
select is((select count(*)::integer from public.whatsapp_guest_authorizations where property_id=:'pid'),0,'booking contact permission never forges ongoing opt-in');
select is((select count(*)::integer from public.whatsapp_marketing_permissions where property_id=:'pid'),0,'booking never grants marketing permission');
set local role service_role;
select is(public.dispatch_whatsapp_automations(50,'https://guest.test'),1,'first welcome queues automatically without ongoing consent');
select is(public.dispatch_whatsapp_automations(50,'https://guest.test'),0,'initial welcome is not repeated');
reset role;
select ok((select body like '%https://guest.test/s/%?view=documents%'from public.messages where automation_event_id is not null and property_id=:'pid'),'welcome opens the exact secure document task');
select is((select template_components#>>'{0,parameters,0,image,link}'from public.messages where automation_event_id is not null and property_id=:'pid'),'https://hotel.test/front.jpg','approved welcome sends its configured hotel image');
select id as cid from public.conversations where property_id=:'pid' \gset
select is(private.inbox_delivery_error((select id from public.messages where property_id=:'pid'and automation_event_id is not null)),null,'initial welcome passes delivery revalidation outside service window');
update public.whatsapp_template_assets set image_url='https://hotel.test/replaced.jpg'where property_id=:'pid';
select is(private.inbox_delivery_error((select id from public.messages where automation_event_id is not null and property_id=:'pid')),'Template delivery image changed.','changed image invalidates the queued photo snapshot');
update public.whatsapp_template_assets set image_url='https://hotel.test/front.jpg'where property_id=:'pid';
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','journey-hi','919111111111','Asha','journey-hi','text','Hi','{}',now());
select is(public.dispatch_whatsapp_guest_replies(50,'https://guest.test'),1,'Hi receives preferences even when no menu was saved');
reset role;
select is((select count(*)::integer from private.whatsapp_journey_actions where conversation_id=:'cid'and action='updates'),1,'stay consent is an actual in-chat button');
select 'journey:'||id as choice from private.whatsapp_journey_actions where conversation_id=:'cid'and action='updates' \gset
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','journey-agree','919111111111','Asha','journey-agree','interactive','Enable stay updates',jsonb_build_object('interactive',jsonb_build_object('button_reply',jsonb_build_object('id',:'choice','title','Enable stay updates'))),now());
select is(public.dispatch_whatsapp_guest_replies(50,'https://guest.test'),1,'consent selection continues the arrival journey');
select is(public.dispatch_whatsapp_guest_replies(50,'https://guest.test'),0,'replayed worker tick repeats no action');
reset role;
select is((select count(*)::integer from public.whatsapp_guest_authorizations where property_id=:'pid'and status='granted'),1,'real inbound button records stay permission');
select is((select source from public.whatsapp_guest_authorizations where property_id=:'pid'),'guest_whatsapp','consent source is the actual guest');
select ok((select source_message_id is not null from public.whatsapp_guest_authorizations where property_id=:'pid'),'consent preserves inbound evidence');
select is((select count(*)::integer from public.whatsapp_marketing_permissions where property_id=:'pid'),0,'stay choice leaves offers off');
select throws_ok($$insert into public.reservations(tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values('e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','e4000000-0000-0000-0000-000000000001','checked_in',current_date,current_date+1,0,'INR')$$,'22023',null,'a checked-in insert cannot skip the document gate');
select throws_ok(format('update public.reservations set status=''checked_in''where id=%L',:'rid'),'22023',null,'document gate cannot be bypassed by a direct status change');
select throws_ok(format('select public.check_in_reservation(%L)',:'rid'),'22023',null,'staff check-in uses the same gate');
insert into public.guest_documents(id,tenant_id,property_id,reservation_id,guest_id,doc_type,storage_path,mime_type,size_bytes,status)values('ed000000-0000-0000-0000-000000000001',:'tenant',:'pid',:'rid',:'guest','id_proof','journey-fixture-1','image/jpeg',10,'clean'),('ed000000-0000-0000-0000-000000000002',:'tenant',:'pid',:'rid',:'guest','passport','journey-fixture-2','image/jpeg',10,'clean');
set local role authenticated;
select public.review_document('ed000000-0000-0000-0000-000000000001','approved','QA fixture review.');
reset role;
select is((select count(*)::integer from public.whatsapp_automation_events where property_id=:'pid'and event_key='documents_approved'),0,'partial document approval does not announce completion');
set local role authenticated;
select public.review_document('ed000000-0000-0000-0000-000000000002','approved','QA fixture review.');
reset role;
select is(private.journey_document_error(:'rid'),null,'all required identity documents complete the review');
select is((select count(*)::integer from public.whatsapp_automation_events where property_id=:'pid'and event_key='documents_approved'),1,'complete document review captures one event');
insert into public.accommodation_types(id,tenant_id,property_id,name,max_occupancy,base_rate)values('ef000000-0000-0000-0000-000000000001',:'tenant',:'pid','Journey Deluxe',2,2500);
insert into public.accommodation_units(id,tenant_id,property_id,type_id,name)values('ef000000-0000-0000-0000-000000000002',:'tenant',:'pid','ef000000-0000-0000-0000-000000000001','J101');
insert into public.unit_holds(tenant_id,property_id,unit_id,reservation_id,during,kind)values(:'tenant',:'pid','ef000000-0000-0000-0000-000000000002',:'rid',daterange(current_date,current_date+2,'[)'),'reservation');
insert into public.property_settings(property_id,tenant_id,check_in_time)values(:'pid',:'tenant','00:00')on conflict(property_id)do update set check_in_time='00:00';
select private.handle_whatsapp_journey(:'cid',(select id from public.messages where wa_message_id='journey-agree'),'checkin','https://guest.test');
select 'journey:'||id as confirm from private.whatsapp_journey_actions where conversation_id=:'cid'and action='confirm_checkin'order by created_at desc limit 1 \gset
select ok(:'confirm'like 'journey:%','guest must confirm check-in explicitly');
update public.whatsapp_connections set status='disabled'where property_id=:'pid';
select is(private.handle_whatsapp_journey(:'cid',(select id from public.messages where wa_message_id='journey-agree'),:'confirm','https://guest.test'),0,'disconnected sender cannot execute a pending guest action');
select is((select status from public.reservations where id=:'rid'),'confirmed','disconnect leaves the stay unchanged');
update public.whatsapp_connections set status='active'where property_id=:'pid';
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','journey-checkin','919111111111','Asha','journey-checkin','interactive','Confirm check-in',jsonb_build_object('interactive',jsonb_build_object('button_reply',jsonb_build_object('id',:'confirm','title','Confirm check-in'))),now());
select public.dispatch_whatsapp_guest_replies(50,'https://guest.test');
reset role;
select is((select status from public.reservations where id=:'rid'),'checked_in','guest confirms real check-in inside WhatsApp');
select ok(exists(select 1 from public.messages where conversation_id=:'cid'and journey_purpose='confirm_checkin'and body like '%J101%'),'check-in confirmation includes room details');
select is((select count(*)::integer from public.reservation_events where reservation_id=:'rid'and event_type='checked_in'),1,'check-in has an operational audit');
select private.handle_whatsapp_journey(:'cid',(select id from public.messages where wa_message_id='journey-checkin'),'bill','https://guest.test');
select ok(exists(select 1 from public.messages where conversation_id=:'cid'and journey_purpose='bill'and outbound_payload#>>'{interactive,action,parameters,url}'like '%?view=bill&via=whatsapp'),'bill action opens the actual bill helper screen');
select substring(outbound_payload#>>'{interactive,action,parameters,url}'from '/s/([a-f0-9]{64})')as helper_token from public.messages where conversation_id=:'cid'and journey_purpose='bill'limit 1 \gset
set local role anon;
select is((public.portal_workspace(:'helper_token')->'journey'->>'enabled')::boolean,true,'private helper learns the selected hotel journey mode');
select is(public.portal_workspace(:'helper_token')->'journey'->>'sender','919999999999','Back to WhatsApp uses this hotel sender, not the staff portal');
reset role;
-- Replay the old button under a different provider ID: it must not repeat the operation.
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','journey-replay','919111111111','Asha','journey-replay','interactive','Confirm check-in',jsonb_build_object('interactive',jsonb_build_object('button_reply',jsonb_build_object('id',:'confirm','title','Confirm check-in'))),now());
select public.dispatch_whatsapp_guest_replies(50,'https://guest.test');
reset role;
select is((select count(*)::integer from public.reservation_events where reservation_id=:'rid'and event_type='checked_in'),1,'consumed button cannot check in again');
insert into public.service_categories(id,tenant_id,property_id,name)values('ee000000-0000-0000-0000-000000000001',:'tenant',:'pid','Room care');
insert into public.service_catalog(id,tenant_id,property_id,category_id,name)values('ee000000-0000-0000-0000-000000000002',:'tenant',:'pid','ee000000-0000-0000-0000-000000000001','Fresh towels');
insert into public.service_routing_rules(tenant_id,property_id,catalog_id,task_kind)values(:'tenant',:'pid','ee000000-0000-0000-0000-000000000002','housekeeping');
select private.journey_button(:'cid',:'rid','service_confirm','Send request',jsonb_build_object('catalog_id','ee000000-0000-0000-0000-000000000002','catalog_version',1))as btn \gset
select private.handle_whatsapp_journey(:'cid',(select id from public.messages where wa_message_id='journey-replay'),(:'btn'::jsonb)->>'id','https://guest.test');
select is((select count(*)::integer from public.guest_requests where reservation_id=:'rid'and source='whatsapp'),1,'WhatsApp selection creates an actual service request');
select is((select count(*)::integer from public.tasks where reservation_id=:'rid'and guest_request_id is not null),1,'service routing creates the staff task');
select private.journey_button(:'cid',:'rid','service_confirm','Send request',jsonb_build_object('catalog_id','ee000000-0000-0000-0000-000000000002','catalog_version',1))as btn \gset
select private.handle_whatsapp_journey(:'cid',(select id from public.messages where wa_message_id='journey-replay'),(:'btn'::jsonb)->>'id','https://guest.test');
select is((select count(*)::integer from public.guest_requests where reservation_id=:'rid'and source='whatsapp'),1,'same open service request is reused instead of duplicating staff work');
select private.journey_button(:'cid',:'rid','menu','Guest menu')as btn \gset
update private.whatsapp_journey_actions set expires_at=now()-interval '1 minute'where id=substring((:'btn'::jsonb)->>'id'from 9)::uuid;
select private.handle_whatsapp_journey(:'cid',(select id from public.messages where wa_message_id='journey-replay'),(:'btn'::jsonb)->>'id','https://guest.test');
select ok(exists(select 1 from public.messages where conversation_id=:'cid'and journey_purpose='expired'),'expired selection tells guest to get fresh options');
-- Checkout remains a confirmed chat action and uses the existing full-stay settlement core.
select private.journey_button(:'cid',:'rid','confirm_checkout','Confirm checkout')as btn \gset
insert into public.messages(tenant_id,property_id,conversation_id,direction,type,body,status)values(:'tenant',:'pid',:'cid','in','text','Confirm checkout','received')returning id as source \gset
select private.handle_whatsapp_journey(:'cid',:'source',(:'btn'::jsonb)->>'id','https://guest.test');
select is((select status from public.reservations where id=:'rid'),'checked_in','outstanding full-stay charges block WhatsApp checkout');
select is(private.reservation_balance(:'rid'),5000::numeric,'checkout review posts the full booked room charge');
insert into public.payments(tenant_id,property_id,folio_id,amount,method)select :'tenant',:'pid',id,5000,'cash'from public.folios where reservation_id=:'rid';
insert into public.orders(id,tenant_id,property_id,kind,reservation_id,total)values('ec000000-0000-0000-0000-000000000001',:'tenant',:'pid','room_service',:'rid',0);
select private.journey_button(:'cid',:'rid','confirm_checkout','Confirm checkout')as btn \gset
insert into public.messages(tenant_id,property_id,conversation_id,direction,type,body,status)values(:'tenant',:'pid',:'cid','in','text','Confirm checkout','received')returning id as source \gset
select private.handle_whatsapp_journey(:'cid',:'source',(:'btn'::jsonb)->>'id','https://guest.test');
select is((select status from public.reservations where id=:'rid'),'checked_in','unfinished food order blocks checkout even after payment');
update public.orders set status='served'where id='ec000000-0000-0000-0000-000000000001';
select private.journey_button(:'cid',:'rid','confirm_checkout','Confirm checkout')as btn \gset
insert into public.messages(tenant_id,property_id,conversation_id,direction,type,body,status)values(:'tenant',:'pid',:'cid','in','text','Confirm checkout','received')returning id as source \gset
select private.handle_whatsapp_journey(:'cid',:'source',(:'btn'::jsonb)->>'id','https://guest.test');
select is((select status from public.reservations where id=:'rid'),'checked_out','settled guest checks out in WhatsApp');
select is((select housekeeping_status from public.accommodation_units where id='ef000000-0000-0000-0000-000000000002'),'dirty','checkout marks the occupied room dirty');
select is((select count(*)::integer from public.tasks where reservation_id=:'rid'and kind='housekeeping'and unit_id='ef000000-0000-0000-0000-000000000002'),1,'checkout queues room cleaning');
select is((select count(*)::integer from public.unit_holds where reservation_id=:'rid'and active),0,'early departure releases future inventory');
select is(private.inbox_delivery_error((select id from public.messages where guest_reply_to=:'source'and journey_purpose='confirm_checkout')),null,'checkout confirmation can deliver after the stay closes');
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','journey-stop','919111111111','Asha','journey-stop','text','STOP','{}',now());
reset role;
select is((select status from public.whatsapp_guest_authorizations where property_id=:'pid'),'revoked','STOP revokes chat stay-update permission');
select ok(private.inbox_delivery_error((select id from public.messages where journey_purpose='confirm_checkin'and property_id=:'pid'))is not null,'STOP suppresses already queued journey replies');
select ok(not has_function_privilege('anon','public.save_whatsapp_journey(uuid,integer,boolean,integer,boolean,text)','execute'),'anonymous visitor cannot change journey settings');
select ok(not has_function_privilege('authenticated','private.complete_guest_checkout(uuid,uuid)','execute'),'staff cannot invoke the private guest checkout core directly');
set local role authenticated;
select throws_ok($$select public.frontdesk_create_whatsapp(p_property=>'e3000000-0000-0000-0000-000000000001',p_currency=>'INR',p_request=>'ea000000-0000-0000-0000-000000000001',p_guest_name=>'Atomic invalid QA',p_phone=>'+919333333333',p_email=>'',p_type=>'ef000000-0000-0000-0000-000000000001',p_in=>current_date+5,p_out=>current_date+7,p_adults=>1,p_children=>0,p_quote=>5000,p_contact_permission=>true,p_contact_evidence=>'')$$,'22023',null,'booking with invalid contact evidence fails atomically');
reset role;
select is((select count(*)::integer from public.reservations where creation_request_id='ea000000-0000-0000-0000-000000000001'),0,'failed contact evidence does not leave a half-created reservation');
set local role authenticated;
select public.frontdesk_create_whatsapp(p_property=>:'pid',p_currency=>'INR',p_request=>'ea000000-0000-0000-0000-000000000002',p_guest_name=>'Atomic welcome QA',p_phone=>'+919333333333',p_email=>'',p_type=>'ef000000-0000-0000-0000-000000000001',p_in=>current_date+5,p_out=>current_date+7,p_adults=>1,p_children=>0,p_quote=>5000,p_contact_permission=>true,p_contact_evidence=>'Synthetic QA booking: guest requested a welcome at booking.')as atomic_rid \gset
reset role;
select ok(exists(select 1 from private.whatsapp_booking_contacts b join public.whatsapp_automation_events e on e.reservation_id=b.reservation_id where b.reservation_id=:'atomic_rid'and e.event_key='booking_confirmed'),'booking API records welcome permission and captures the first automatic message in one transaction');
select guest_id as returning_guest from public.reservations where id=:'atomic_rid' \gset
set local role authenticated;
select throws_ok($$select public.frontdesk_guest_choices('e3000000-0000-0000-0000-000000000002')$$,'42501',null,'returning guest choices cannot expose another hotel');
select public.frontdesk_create_existing_guest(p_property=>:'pid',p_currency=>'INR',p_request=>'ea000000-0000-0000-0000-000000000003',p_guest=>:'returning_guest',p_type=>'ef000000-0000-0000-0000-000000000001',p_in=>current_date+9,p_out=>current_date+11,p_adults=>1,p_children=>0,p_quote=>5000,p_contact_permission=>true,p_contact_evidence=>'Synthetic QA repeat stay: guest requested a new booking welcome.')as repeat_rid \gset
select is(public.frontdesk_create_existing_guest(p_property=>:'pid',p_currency=>'INR',p_request=>'ea000000-0000-0000-0000-000000000003',p_guest=>:'returning_guest',p_type=>'ef000000-0000-0000-0000-000000000001',p_in=>current_date+9,p_out=>current_date+11,p_adults=>1,p_children=>0,p_quote=>5000,p_contact_permission=>true,p_contact_evidence=>'Synthetic QA repeat stay: guest requested a new booking welcome.'),:'repeat_rid'::uuid,'retrying a returning guest booking is idempotent');
reset role;
select is((select guest_id from public.reservations where id=:'repeat_rid'),:'returning_guest'::uuid,'returning booking preserves the selected guest profile');
select is((select count(*)::integer from public.guests where tenant_id=:'tenant'and full_name='Atomic welcome QA'),1,'repeat stay creates no duplicate guest or WhatsApp identity');
select ok(exists(select 1 from private.whatsapp_booking_contacts b join public.whatsapp_automation_events e on e.reservation_id=b.reservation_id and e.guest_id=b.guest_id where b.reservation_id=:'repeat_rid'and b.guest_id=:'returning_guest'),'repeat welcome uses the same verified guest identity');
select *from finish();
rollback;
