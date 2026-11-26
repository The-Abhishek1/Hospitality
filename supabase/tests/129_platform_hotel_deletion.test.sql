begin;
set local search_path=public,extensions;
select no_plan();
insert into auth.users(id,email,email_confirmed_at)values
 ('f1290000-0000-0000-0000-000000000001','delete-owner@test.invalid',now()),
 ('f1290000-0000-0000-0000-000000000002','delete-admin@test.invalid',now());
insert into public.platform_admins values('f1290000-0000-0000-0000-000000000002');
insert into public.tenants(id,name,slug)values('f1291000-0000-0000-0000-000000000001','Deletion QA','deletion-qa-129');
insert into public.tenant_memberships(tenant_id,user_id,role)values('f1291000-0000-0000-0000-000000000001','f1290000-0000-0000-0000-000000000001','owner');
insert into public.properties(id,tenant_id,name,property_type)values
 ('f1292000-0000-0000-0000-000000000001','f1291000-0000-0000-0000-000000000001','Delete Hotel','hotel'),
 ('f1292000-0000-0000-0000-000000000002','f1291000-0000-0000-0000-000000000001','Keep Hotel','hotel');
insert into public.accommodation_types(id,tenant_id,property_id,name,max_occupancy,base_rate)values
 ('f1293000-0000-0000-0000-000000000001','f1291000-0000-0000-0000-000000000001','f1292000-0000-0000-0000-000000000001','Standard',2,100),
 ('f1293000-0000-0000-0000-000000000002','f1291000-0000-0000-0000-000000000001','f1292000-0000-0000-0000-000000000002','Standard',2,100);
insert into public.accommodation_units(tenant_id,property_id,type_id,name)select tenant_id,property_id,id,'101'from public.accommodation_types where id::text like 'f1293000%';
insert into public.guests(id,tenant_id,full_name)values
 ('f1294000-0000-0000-0000-000000000001','f1291000-0000-0000-0000-000000000001','Exclusive guest'),
 ('f1294000-0000-0000-0000-000000000002','f1291000-0000-0000-0000-000000000001','Shared guest');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f1290000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select public.platform_hotel_deletion_preview('f1292000-0000-0000-0000-000000000001')$$,'42501',null,'Hotel owners cannot preview permanent platform deletion');
select throws_ok($$select public.platform_hotel_deletion_begin('f1292000-0000-0000-0000-000000000001','f1290000-0000-0000-0000-000000000002',gen_random_uuid(),1,'Delete Hotel','QA cleanup')$$,'42501',null,'Browser roles cannot call backend mutator even with an admin actor ID');
select set_config('test.reservation',public.create_reservation('f1292000-0000-0000-0000-000000000001','f1294000-0000-0000-0000-000000000001','f1293000-0000-0000-0000-000000000001',current_date-2,current_date,1,0)::text,true);
select public.check_in_reservation(current_setting('test.reservation')::uuid);
select public.collect_folio_payment(public.post_room_charges(current_setting('test.reservation')::uuid),200,'cash');
select public.check_out_reservation(current_setting('test.reservation')::uuid);
select public.finalize_invoice((select id from public.folios where reservation_id=current_setting('test.reservation')::uuid));
select set_config('test.future',public.create_reservation('f1292000-0000-0000-0000-000000000001','f1294000-0000-0000-0000-000000000002','f1293000-0000-0000-0000-000000000001',current_date+5,current_date+6,1,0)::text,true);
select public.create_reservation('f1292000-0000-0000-0000-000000000002','f1294000-0000-0000-0000-000000000002','f1293000-0000-0000-0000-000000000002',current_date+5,current_date+6,1,0);
reset role;
insert into public.whatsapp_connections(id,tenant_id,property_id,phone_number_id,waba_id,display_phone,credentials_ref)values('f1295000-0000-0000-0000-000000000001','f1291000-0000-0000-0000-000000000001','f1292000-0000-0000-0000-000000000001','12900000001','12900000002','+919000000129','managed:f1292000-0000-0000-0000-000000000001');
insert into private.whatsapp_credentials values('f1292000-0000-0000-0000-000000000001','managed:f1292000-0000-0000-0000-000000000001',repeat('a',80),now());
insert into public.conversations(id,tenant_id,property_id,connection_id,wa_contact_id)values('f1296000-0000-0000-0000-000000000001','f1291000-0000-0000-0000-000000000001','f1292000-0000-0000-0000-000000000001','f1295000-0000-0000-0000-000000000001','919000000129');
insert into public.messages(id,tenant_id,property_id,conversation_id,direction,type,body,status)values('f1297000-0000-0000-0000-000000000001','f1291000-0000-0000-0000-000000000001','f1292000-0000-0000-0000-000000000001','f1296000-0000-0000-0000-000000000001','out','text','Synthetic message','sending');
insert into public.menu_categories(id,tenant_id,property_id,name)values('f1299000-0000-0000-0000-000000000001','f1291000-0000-0000-0000-000000000001','f1292000-0000-0000-0000-000000000001','Food');
insert into public.menu_items(id,tenant_id,property_id,category_id,name,price)values('f1299100-0000-0000-0000-000000000001','f1291000-0000-0000-0000-000000000001','f1292000-0000-0000-0000-000000000001','f1299000-0000-0000-0000-000000000001','Tea',50);
insert into public.menu_item_variants(menu_item_id,property_id,label,price)values('f1299100-0000-0000-0000-000000000001','f1292000-0000-0000-0000-000000000001','Large',100);
insert into public.orders(id,tenant_id,property_id,kind)values('f1299200-0000-0000-0000-000000000001','f1291000-0000-0000-0000-000000000001','f1292000-0000-0000-0000-000000000001','restaurant');
insert into public.order_items(tenant_id,property_id,order_id,menu_item_id,name_snapshot,unit_price,tax_rate_percent,quantity)values('f1291000-0000-0000-0000-000000000001','f1292000-0000-0000-0000-000000000001','f1299200-0000-0000-0000-000000000001','f1299100-0000-0000-0000-000000000001','Tea',50,0,1);
insert into public.tasks(tenant_id,property_id,title)values('f1291000-0000-0000-0000-000000000001','f1292000-0000-0000-0000-000000000001','Clean room');
insert into public.guest_requests(tenant_id,property_id,reservation_id,title,source)values('f1291000-0000-0000-0000-000000000001','f1292000-0000-0000-0000-000000000001',current_setting('test.future')::uuid,'Fresh towels','staff');
insert into public.guest_documents(tenant_id,property_id,reservation_id,guest_id,doc_type,storage_path,mime_type,size_bytes)values('f1291000-0000-0000-0000-000000000001','f1292000-0000-0000-0000-000000000001',current_setting('test.reservation')::uuid,'f1294000-0000-0000-0000-000000000001','id_proof','f1291000-0000-0000-0000-000000000001/f1292000-0000-0000-0000-000000000001/doc.jpg','image/jpeg',100);
insert into public.hotel_payment_connections(id,tenant_id,property_id,mode,key_hint)values('f1299300-0000-0000-0000-000000000001','f1291000-0000-0000-0000-000000000001','f1292000-0000-0000-0000-000000000001','test','synthetic');
insert into private.hotel_payment_credentials values('f1299300-0000-0000-0000-000000000001','synthetic-only');
insert into private.hotel_payment_webhooks values('f1299300-0000-0000-0000-000000000001','synthetic-event','synthetic-hash',now());
insert into public.hotel_payment_requests(id,tenant_id,property_id,reservation_id,folio_id,connection_id,request_id,amount,currency,state)
select 'f1299400-0000-0000-0000-000000000001',tenant_id,property_id,reservation_id,id,'f1299300-0000-0000-0000-000000000001',gen_random_uuid(),200,'INR','ready'from public.folios where reservation_id=current_setting('test.reservation')::uuid;
insert into public.staff_invitations(id,tenant_id,email,tenant_role,grants)values('f1299500-0000-0000-0000-000000000001','f1291000-0000-0000-0000-000000000001','member@test.invalid','member','[{"property_id":"f1292000-0000-0000-0000-000000000001","role_key":"manager"},{"property_id":"f1292000-0000-0000-0000-000000000002","role_key":"manager"}]');
insert into public.whatsapp_guest_feedback(id,tenant_id,property_id,reservation_id,guest_id,kind,target_id,rating,conversation_id,source_message_id)values('f1299600-0000-0000-0000-000000000001','f1291000-0000-0000-0000-000000000001','f1292000-0000-0000-0000-000000000001',current_setting('test.reservation')::uuid,'f1294000-0000-0000-0000-000000000001','stay',current_setting('test.reservation')::uuid,5,'f1296000-0000-0000-0000-000000000001','f1297000-0000-0000-0000-000000000001');
insert into private.whatsapp_feedback_followups(conversation_id,feedback_id)values('f1296000-0000-0000-0000-000000000001','f1299600-0000-0000-0000-000000000001');
insert into private.whatsapp_guest_inbound_jobs(message_id,command)values('f1297000-0000-0000-0000-000000000001','hi');
create function pg_temp.begin_delete()returns uuid language sql as $$select public.platform_hotel_deletion_begin('f1292000-0000-0000-0000-000000000001','f1290000-0000-0000-0000-000000000002','f1298000-0000-0000-0000-000000000001',(select version from public.properties where id='f1292000-0000-0000-0000-000000000001'),'Delete Hotel','Synthetic local QA cleanup')$$;
select throws_ok($$select pg_temp.begin_delete()$$,'55000',null,'In-flight WhatsApp delivery blocks deletion');
update public.messages set status='queued'where id='f1297000-0000-0000-0000-000000000001';
select throws_ok($$select pg_temp.begin_delete()$$,'55000',null,'An open payment link blocks deletion');
update public.hotel_payment_requests set state='expired',expires_at=now()-interval '1 minute'where id='f1299400-0000-0000-0000-000000000001';
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f1290000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select is(public.platform_hotel_deletion_preview('f1292000-0000-0000-0000-000000000001')#>>'{counts,reservations}','2','Admin preview counts historical and future reservations');
select ok(public.platform_hotel_deletion_preview('f1292000-0000-0000-0000-000000000001')::text not like '%Exclusive guest%','Admin preview reveals no guest content');
reset role;
-- Metadata-only fixture verifies the database never bypasses the Storage API phase.
-- Physical upload/removal is exercised separately through the local Storage service.
insert into storage.objects(bucket_id,name)values('hotel-whatsapp-photos','f1292000-0000-0000-0000-000000000001/orphan.jpg');
select lives_ok($$select pg_temp.begin_delete()$$,'Admin begins deletion of populated hotel including paid historical data');
select is(pg_temp.begin_delete(),'f1298000-0000-0000-0000-000000000001'::uuid,'Begin retry reuses its durable deletion job');
select is((select count(*)::int from private.whatsapp_credentials where property_id='f1292000-0000-0000-0000-000000000001'),0,'Saved WhatsApp secret is removed before file cleanup');
select is((select status from public.messages where id='f1297000-0000-0000-0000-000000000001'),'failed','Queued sends cannot escape during cleanup');
select is((select state from private.whatsapp_guest_inbound_jobs where message_id='f1297000-0000-0000-0000-000000000001'),'done','Pending guest replies stop before an interrupted cleanup');
select is((select enabled from public.whatsapp_default_setup where property_id='f1292000-0000-0000-0000-000000000001'),false,'Default template provisioning is disabled during cleanup');
select is(private.has_property_access('f1292000-0000-0000-0000-000000000001'),false,'Frozen hotel denies staff access');
select throws_ok($$update public.properties set archived_at=null where id='f1292000-0000-0000-0000-000000000001'$$,'55000',null,'Frozen hotel cannot be reopened');
select throws_ok($$insert into storage.objects(bucket_id,name)values('hotel-whatsapp-photos','f1292000-0000-0000-0000-000000000001/late.jpg')$$,'55000',null,'An old upload URL cannot recreate hotel media during deletion');
select is(public.platform_hotel_deletion_step('f1298000-0000-0000-0000-000000000001','f1290000-0000-0000-0000-000000000002')->>'state','files','Database cleanup waits for uploaded files');
select is((select count(*)::int from public.reservations where property_id='f1292000-0000-0000-0000-000000000001'),2,'Records are retained until all physical files are removed');
-- Only this synthetic metadata fixture uses SQL removal; production uses Storage.remove().
select set_config('storage.allow_delete_query','true',true);
delete from storage.objects where bucket_id='hotel-whatsapp-photos'and name='f1292000-0000-0000-0000-000000000001/orphan.jpg';
select lives_ok($$select public.platform_hotel_deletion_step('f1298000-0000-0000-0000-000000000001','f1290000-0000-0000-0000-000000000002')$$,'Complete cascade removes populated billing, WhatsApp and room records');
select is((select count(*)::int from public.properties where id='f1292000-0000-0000-0000-000000000001'),0,'Deleted hotel is gone');
select is((select count(*)::int from public.guests where id='f1294000-0000-0000-0000-000000000001'),0,'Exclusive guest profile is removed');
select is((select count(*)::int from public.guests where id='f1294000-0000-0000-0000-000000000002'),1,'Guest used by another hotel is preserved');
select is((select count(*)::int from public.reservations where property_id='f1292000-0000-0000-0000-000000000002'),1,'Other hotel reservations are preserved');
select is((select count(*)::int from public.invoices where property_id='f1292000-0000-0000-0000-000000000001'),0,'Invoices are included in permanent deletion');
select is((select count(*)::int from public.payments where property_id='f1292000-0000-0000-0000-000000000001'),0,'Payment records are included in permanent deletion');
select is((select count(*)::int from public.whatsapp_default_templates where property_id='f1292000-0000-0000-0000-000000000001'),0,'Default WhatsApp templates and setup state are removed');
select is((select count(*)::int from public.platform_audit_logs where action='platform_hotel_deleted'and details->>'property_id'='f1292000-0000-0000-0000-000000000001'),1,'Minimal permanent deletion receipt is retained');
select is(public.platform_hotel_deletion_step('f1298000-0000-0000-0000-000000000001','f1290000-0000-0000-0000-000000000002')->>'state','complete','Finish retry is idempotent');
select throws_ok($$insert into storage.objects(bucket_id,name)values('guest-documents','f1291000-0000-0000-0000-000000000001/f1292000-0000-0000-0000-000000000001/late.jpg')$$,'55000',null,'Old document upload URL is rejected even after hotel deletion');
select is((select count(*)::int from auth.users where id in('f1290000-0000-0000-0000-000000000001','f1290000-0000-0000-0000-000000000002')),2,'Login accounts remain intact');
select is((select count(*)::int from private.hotel_payment_webhooks where connection_id='f1299300-0000-0000-0000-000000000001'),0,'Provider webhook deduplication records are removed');
select is((select count(*)::int from private.hotel_payment_credentials where connection_id='f1299300-0000-0000-0000-000000000001'),0,'Payment credentials are removed');
select is((select jsonb_array_length(grants)from public.staff_invitations where id='f1299500-0000-0000-0000-000000000001'),1,'Shared staff invitation preserves its other hotel grant');
select is((select grants->0->>'property_id'from public.staff_invitations where id='f1299500-0000-0000-0000-000000000001'),'f1292000-0000-0000-0000-000000000002','Deleted hotel cannot be granted by an existing invitation');
select is((select count(*)::int from public.menu_item_variants where property_id='f1292000-0000-0000-0000-000000000001'),0,'Food sizes are included in cleanup');
select is((select count(*)::int from public.guest_documents where property_id='f1292000-0000-0000-0000-000000000001'),0,'Guest document metadata is removed');
select throws_ok($$select public.platform_hotel_deletion_step('f1298000-0000-0000-0000-000000000001','f1290000-0000-0000-0000-000000000001')$$,'42501',null,'Backend rechecks platform membership for every resume');
update public.properties set archived_at=now()where id='f1292000-0000-0000-0000-000000000002';
select lives_ok($$select public.platform_hotel_deletion_begin('f1292000-0000-0000-0000-000000000002','f1290000-0000-0000-0000-000000000002','f1298000-0000-0000-0000-000000000002',(select version from public.properties where id='f1292000-0000-0000-0000-000000000002'),'Keep Hotel','Archived hotel local QA cleanup')$$,'Already archived hotels can also be permanently removed');
select is(public.platform_hotel_deletion_step('f1298000-0000-0000-0000-000000000002','f1290000-0000-0000-0000-000000000002')->>'state','complete','Archived hotel cleanup finishes');
select is((select count(*)::int from public.guests where id='f1294000-0000-0000-0000-000000000002'),0,'Previously shared guest is removed only after its final hotel is deleted');
select is((select status from public.staff_invitations where id='f1299500-0000-0000-0000-000000000001'),'revoked','Invitation for only deleted hotels is revoked');
select is((select count(*)::int from public.tenants where id='f1291000-0000-0000-0000-000000000001'),1,'Business account remains after its final hotel is deleted');
select is((select count(*)::int from private.whatsapp_feedback_followups where conversation_id='f1296000-0000-0000-0000-000000000001'),0,'Private feedback prompts are removed with conversation history');
select *from finish();
rollback;
