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

insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency,checked_out_at)values(:'rid',:'tenant',:'pid',:'guest','checked_out',current_date-2,current_date,0,'INR',now());
insert into public.whatsapp_guest_settings(property_id,tenant_id,data)values(:'pid',:'tenant','{"review_url":"https://reviews.test/hotel"}');
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','poststay-hi','919111111111','Asha','poststay-hi','text','Hi','{}')as cid\gset
reset role;set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,true);
select public.save_whatsapp_journey(:'pid',0,true,1,true,'photo');
reset role;
-- Persist a real verification-shaped authorization fixture for this exact conversation and number.
insert into public.whatsapp_guest_authorizations(property_id,tenant_id,guest_id,wa_contact_id,conversation_id,status,evidence)values(:'pid',:'tenant',:'guest','919111111111',:'cid','granted','Synthetic verified guest authorization');
update public.conversations set guest_id=:'guest'where id=:'cid';
select is(private.poststay_reservation(:'cid'),:'rid'::uuid,'verified completed stay resolves without reopening it');
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','poststay-hi-2','919111111111','Asha','poststay-hi-2','text','Hi','{}');
select is(public.dispatch_whatsapp_guest_replies(50,'https://guest.test'),1,'Hi after checkout receives a useful post-stay menu');
reset role;
select ok(exists(select 1 from public.messages where conversation_id=:'cid'and journey_purpose='post_menu'and body like '%Your stay has ended%'),'post-stay reply explains that the stay has ended');
select is((select count(*)::int from private.whatsapp_journey_actions where conversation_id=:'cid'and action in('post_bill','post_support','post_booking','post_reception','post_review','feedback_stay')),6,'post-stay choices contain bills, feedback, review, support and booking help');
select ok(not exists(select 1 from private.whatsapp_journey_actions where conversation_id=:'cid'and action in('food','checkin','checkout','documents','services')),'post-stay menu excludes expired operational actions');
select 'journey:'||id as bill from private.whatsapp_journey_actions where conversation_id=:'cid'and action='post_bill'limit 1\gset
select is(private.handle_whatsapp_journey(:'cid',(select id from public.messages where wa_message_id='poststay-hi-2'),:'bill','https://guest.test'),1,'verified guest can request their old bill');
select ok(exists(select 1 from public.messages where conversation_id=:'cid'and journey_purpose='post_bill'and outbound_payload#>>'{interactive,action,parameters,url}'like'https://guest.test/s/%/bill?via=whatsapp'),'bill reply opens only the focused bill task');
select 'journey:'||id as rate from private.whatsapp_journey_actions where conversation_id=:'cid'and action='feedback_stay'limit 1\gset
select private.handle_whatsapp_journey(:'cid',(select id from public.messages where wa_message_id='poststay-hi-2'),:'rate','https://guest.test');
select 'journey:'||id as rating from private.whatsapp_journey_actions where conversation_id=:'cid'and action='feedback_score'and details->>'rating'='1'order by created_at desc limit 1\gset
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','poststay-rate','919111111111','Asha','poststay-rate','interactive','Needs attention',jsonb_build_object('interactive',jsonb_build_object('button_reply',jsonb_build_object('id',:'rating','title','Needs attention'))));
select public.dispatch_whatsapp_guest_replies(50,'https://guest.test');
reset role;
select is((select count(*)::int from public.whatsapp_guest_feedback where reservation_id=:'rid'and kind='stay'),1,'WhatsApp rating is saved against the completed stay');
select is((select rating from public.whatsapp_guest_feedback where reservation_id=:'rid'and kind='stay'),1,'low rating is preserved for hotel follow-up');
select is(private.handle_whatsapp_journey(:'cid',(select id from public.messages where wa_message_id='poststay-rate'),:'rating','https://guest.test'),0,'replayed rating button cannot rate twice');
set local role service_role;
select public.ingest_whatsapp_inbound('12345678001','poststay-comment','919111111111','Asha','poststay-comment','text','The room needed attention.','{}');
select public.dispatch_whatsapp_guest_replies(50,'https://guest.test');
reset role;
select is((select comment from public.whatsapp_guest_feedback where reservation_id=:'rid'and kind='stay'),'The room needed attention.','optional follow-up comment is saved to the just-rated experience');
select is((select status from public.reservations where id=:'rid'),'checked_out','feedback and bill access never reopen the stay');
-- Old action buttons are rejected rather than reviving hotel services.
select private.journey_button(:'cid',:'rid','food','Old food button')as old_button\gset
select private.handle_whatsapp_journey(:'cid',(select id from public.messages where wa_message_id='poststay-comment'),(:'old_button'::jsonb)->>'id','https://guest.test');
select is((select count(*)::int from public.orders where reservation_id=:'rid'),0,'old food actions cannot order after checkout');
-- New verified upcoming reservations take priority over past-stay help.
insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values('11600000-0000-4000-8000-000000000001',:'tenant',:'pid',:'guest','confirmed',current_date+1,current_date+2,500,'INR');
select is(private.poststay_reservation(:'cid'),null::uuid,'an upcoming stay suppresses the completed-stay context');
select is(private.journey_stay(:'cid'),'11600000-0000-4000-8000-000000000001'::uuid,'new active booking receives the active guest journey');
insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values('11600000-0000-4000-8000-000000000002',:'tenant',:'pid',:'guest','confirmed',current_date+1,current_date+2,500,'INR');
select is(private.journey_stay(:'cid'),null::uuid,'ambiguous active bookings do not expose a guessed stay');
select is(private.poststay_reservation(:'cid'),null::uuid,'ambiguity cannot fall back to an unrelated old bill');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"e1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select is((select count(*)::int from public.whatsapp_guest_feedback where property_id=:'pid'),0,'feedback stays isolated from another hotel');
reset role;
select *from finish();rollback;
