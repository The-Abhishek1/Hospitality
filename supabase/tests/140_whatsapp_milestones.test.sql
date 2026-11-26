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
insert into public.whatsapp_journey_settings(property_id,enabled)values(:'pid',true);
insert into public.conversations(id,tenant_id,property_id,connection_id,wa_contact_id,contact_name,guest_id,last_inbound_at)values('e7000000-0000-0000-0000-000000000001',:'tenant',:'pid','e6000000-0000-0000-0000-000000000001','919111111111','Asha',:'guest',now());
\set cid e7000000-0000-0000-0000-000000000001

update public.whatsapp_default_setup set configured_by=:'owner',enabled=true where property_id=:'pid';
insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values(:'rid',:'tenant',:'pid',:'guest','confirmed',current_date,current_date+1,5000,'INR');
insert into private.whatsapp_booking_contacts(reservation_id,property_id,guest_id,conversation_id,phone,evidence,actor_id)values(:'rid',:'pid',:'guest',:'cid','919111111111','Guest requested a booking welcome on this number.',null);
insert into public.messages(id,tenant_id,property_id,conversation_id,direction,type,body,status)values('a1400000-0000-0000-0000-000000000001',:'tenant',:'pid',:'cid','in','text','Hi','received');
\set source a1400000-0000-0000-0000-000000000001
select private.capture_whatsapp_event(:'pid',:'rid','booking_confirmed','different-retry','reservations',:'rid','confirmed');
select is((select count(*)::integer from public.whatsapp_automation_events where reservation_id=:'rid'and event_key='booking_confirmed'),1,'welcome captures once per reservation across retries');
select is(public.dispatch_whatsapp_automations(50,'https://hotel.test'),1,'a verified booking contact gets its welcome in the open window while templates await approval');
select ok(exists(select 1 from public.messages where conversation_id=:'cid'and body like '%Check-in: %'and body ~ '[0-9]{2}-[0-9]{2}-[0-9]{4}'and body like '%/s/%?view=documents%'),'welcome has formatted dates and a document-specific secure link');
select id as welcome from public.messages where conversation_id=:'cid'and automation_native limit 1 \gset
select is(private.inbox_delivery_error(:'welcome'),null::text,'native welcome passes delivery-time identity validation');
select is(public.dispatch_whatsapp_automations(50,'https://hotel.test'),0,'a second worker pass does not send another welcome');
insert into public.guest_documents(id,tenant_id,property_id,reservation_id,guest_id,doc_type,storage_path,mime_type,size_bytes,status,review_method)values('a1400000-0000-0000-0000-000000000002',:'tenant',:'pid',:'rid',:'guest','aadhaar','140-synthetic-photo','image/jpeg',10,'pending_upload','photo');
update public.guest_documents set status='uploaded'where id='a1400000-0000-0000-0000-000000000002';
update public.guest_documents set status='image_ready'where id='a1400000-0000-0000-0000-000000000002';
select is((select count(*)::integer from public.whatsapp_automation_events where reservation_id=:'rid'and event_key='documents_received'),1,'image rebuild does not duplicate the upload event');
select is(public.dispatch_whatsapp_automations(50,'https://hotel.test'),1,'document upload automatically sends one receipt without a provider template');
select ok(exists(select 1 from public.messages where conversation_id=:'cid'and body like 'Your document upload%'),'receipt tells the guest that hotel review is pending');
update public.guest_documents set status='approved'where id='a1400000-0000-0000-0000-000000000002';
select is(private.journey_document_error(:'rid'),null::text,'approved Aadhaar satisfies identity requirements');
select is(public.dispatch_whatsapp_automations(50,'https://hotel.test'),1,'approval automatically sends the document-completion message');
select private.capture_whatsapp_event(:'pid',:'rid','documents_approved','repeated-review','guest_documents','a1400000-0000-0000-0000-000000000002','approved');
select is((select count(*)::integer from public.whatsapp_automation_events where reservation_id=:'rid'and event_key='documents_approved'),1,'the same approved document set has one completion receipt');
insert into public.whatsapp_guest_authorizations(property_id,tenant_id,guest_id,wa_contact_id,conversation_id,status,evidence)values(:'pid',:'tenant',:'guest','919111111111',:'cid','granted','Guest enabled ongoing stay updates.');
update public.reservations set status='checked_in'where id=:'rid';
select private.handle_whatsapp_journey(:'cid',:'source','services','https://hotel.test');
select ok(exists(select 1 from private.whatsapp_journey_actions where conversation_id=:'cid'and action='quick_service_prompt'),'service menu offers common requests without a configured catalog');
select 'journey:'||id as prompt from private.whatsapp_journey_actions where conversation_id=:'cid'and action='quick_service_prompt'and details->>'service'='Fresh towels'limit 1 \gset
select private.handle_whatsapp_journey(:'cid',:'source',:'prompt','https://hotel.test');
select 'journey:'||id as choice from private.whatsapp_journey_actions where conversation_id=:'cid'and action='quick_service_confirm'limit 1 \gset
select private.handle_whatsapp_journey(:'cid',:'source',:'choice','https://hotel.test');
select is((select count(*)::integer from public.guest_requests where reservation_id=:'rid'),1,'confirmed WhatsApp service creates a real guest request');
select is((select count(*)::integer from public.tasks where reservation_id=:'rid'and guest_request_id is not null),1,'guest request creates linked work');
select is(private.handle_whatsapp_journey(:'cid',:'source',:'choice','https://hotel.test'),0,'replaying service confirmation cannot create another request');
select public.dispatch_whatsapp_automations(50,'https://hotel.test');
update public.tasks set status='in_progress'where reservation_id=:'rid'and guest_request_id is not null;
select public.dispatch_whatsapp_automations(50,'https://hotel.test');
update public.tasks set status='done'where reservation_id=:'rid'and guest_request_id is not null;
select public.dispatch_whatsapp_automations(50,'https://hotel.test');
select is((select count(*)::integer from public.whatsapp_automation_events where reservation_id=:'rid'and event_key in('request_received','request_started','request_completed')and state='queued'),3,'request receipt, progress and completion all queue automatically');
insert into public.orders(id,tenant_id,property_id,reservation_id,kind,status)values('a1400000-0000-0000-0000-000000000003',:'tenant',:'pid',:'rid','room_service','placed');
update public.orders set status='preparing'where id='a1400000-0000-0000-0000-000000000003';
update public.orders set status='ready'where id='a1400000-0000-0000-0000-000000000003';
update public.orders set status='serving'where id='a1400000-0000-0000-0000-000000000003';
update public.orders set status='served'where id='a1400000-0000-0000-0000-000000000003';
select public.dispatch_whatsapp_automations(50,'https://hotel.test');
select is((select count(*)::integer from public.whatsapp_automation_events where reservation_id=:'rid'and event_key in('order_placed','order_preparing','order_ready','order_serving','order_served')and state='queued'),5,'all five food milestones survive fast consecutive status changes');
insert into public.hotel_message_photos(id,property_id,name,url,mime_type)values('a1400000-0000-0000-0000-000000000004',:'pid','Hotel photo','https://hotel.test/photo.jpg','image/jpeg');
select is(private.handle_whatsapp_journey(:'cid',:'source','photos','https://hotel.test'),1,'Photos sends saved public hotel media');
select ok(exists(select 1 from public.messages where conversation_id=:'cid'and type='image'and outbound_payload#>>'{image,link}'='https://hotel.test/photo.jpg'),'photo reply contains the actual image');
update public.conversations set guest_id=null where id=:'cid';
select ok(private.inbox_delivery_error(:'welcome')is not null,'changing guest binding blocks a queued private receipt');
update public.property_settings set cleaning_checklist='["Bedroom › Change linens","Bathroom › Clean surfaces"]'where property_id=:'pid';
insert into public.guest_requests(id,tenant_id,property_id,reservation_id,title,source)values('a1400000-0000-0000-0000-000000000005',:'tenant',:'pid',:'rid','Room cleaning','whatsapp');
insert into public.tasks(id,tenant_id,property_id,reservation_id,guest_request_id,title,kind)values('a1400000-0000-0000-0000-000000000006',:'tenant',:'pid',:'rid','a1400000-0000-0000-0000-000000000005','Room cleaning','housekeeping');
select is((select count(*)::integer from public.task_checklists where task_id='a1400000-0000-0000-0000-000000000006'),2,'guest-request cleaning also snapshots all configured categories');
select *from finish();rollback;
