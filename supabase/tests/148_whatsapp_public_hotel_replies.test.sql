begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select no_plan();
insert into auth.users(id,email)values('a1480000-0000-0000-0000-000000000001','public-enquiry-owner@test.invalid');
insert into public.tenants(id,name,slug)values('b1480000-0000-0000-0000-000000000001','Public Enquiry QA','public-enquiry-qa');
insert into public.properties(id,tenant_id,name,property_type,address,city,contact_phone,contact_email)values
('c1480000-0000-0000-0000-000000000001','b1480000-0000-0000-0000-000000000001','Forest View Resort','resort','10 Forest Road','Coorg','+919000001480','hello@forest.test'),
('c1480000-0000-0000-0000-000000000002','b1480000-0000-0000-0000-000000000001','Other Hotel','hotel','Private other address','Other city','','');
\set pid c1480000-0000-0000-0000-000000000001
\set tenant b1480000-0000-0000-0000-000000000001
insert into public.tenant_memberships(tenant_id,user_id,role)values(:'tenant','a1480000-0000-0000-0000-000000000001','owner');
insert into public.whatsapp_connections(id,tenant_id,property_id,phone_number_id,waba_id,credentials_ref)values('d1480000-0000-0000-0000-000000000001',:'tenant',:'pid','148001','148002','synthetic-public-enquiries');
insert into public.whatsapp_journey_settings(property_id,enabled)values(:'pid',true);
update public.whatsapp_default_setup set configured_by='a1480000-0000-0000-0000-000000000001',enabled=true,welcome_image_url='https://forest.test/collage.jpg'where property_id=:'pid';
update public.property_settings set check_in_time='13:00',check_out_time='11:30',stay_information='PRIVATE WIFI PASSWORD 148',arrival_instructions='PRIVATE DOOR CODE 148'where property_id=:'pid';
insert into public.hotel_message_photos(id,property_id,name,url,mime_type)values
('e1480000-0000-0000-0000-000000000001',:'pid','Exterior','https://forest.test/exterior.jpg','image/jpeg'),
('e1480000-0000-0000-0000-000000000002',:'pid','Welcome collage','https://forest.test/collage.jpg','image/jpeg'),
('e1480000-0000-0000-0000-000000000003','c1480000-0000-0000-0000-000000000002','Other photo','https://other.test/photo.jpg','image/jpeg');
insert into public.whatsapp_guest_settings(property_id,tenant_id,data)values(:'pid',:'tenant','{"maps_url":"https://maps.example/forest","website_url":"https://forest.test","review_url":"https://reviews.example/forest"}');
insert into public.accommodation_types(id,tenant_id,property_id,name,base_rate,max_occupancy)values('f1480000-0000-0000-0000-000000000001',:'tenant',:'pid','Garden Deluxe',5500,3),('f1480000-0000-0000-0000-000000000002',:'tenant',:'pid','Inactive hidden room',999,2);
insert into public.accommodation_units(tenant_id,property_id,type_id,name)values(:'tenant',:'pid','f1480000-0000-0000-0000-000000000001','GD101');
create function pg_temp.incoming(p_phone text,p_body text,p_key text)returns uuid language plpgsql as $$declare cid uuid;begin
 cid:=public.ingest_whatsapp_inbound('148001',p_key,p_phone,'New Customer',p_key,case when p_body like'journey:%'then'interactive'else'text'end,p_body,case when p_body like'journey:%'then jsonb_build_object('interactive',jsonb_build_object('button_reply',jsonb_build_object('id',p_body,'title','Choose')))else'{}'::jsonb end,now());
 perform public.dispatch_whatsapp_guest_replies(50,'https://hotel.test');return cid;
end $$;
select pg_temp.incoming('919000001481','Hi','148-hi')as cid \gset
select id as welcome from public.messages where conversation_id=:'cid'and direction='out'and body like'Welcome to Forest View Resort!%' \gset
select is((select outbound_payload#>>'{interactive,header,image,link}'from public.messages where id=:'welcome'),'https://forest.test/collage.jpg','unknown greeting includes the saved hotel welcome collage');
select is((select jsonb_array_length(outbound_payload#>'{interactive,action,buttons}')from public.messages where id=:'welcome'),3,'welcome keeps all existing booking and reception buttons');
select is(private.inbox_delivery_error(:'welcome'),null::text,'public image welcome passes real delivery guards');
select pg_temp.incoming('919000001481','Can you share hotel details please?','148-details');
select ok(exists(select 1 from public.messages where conversation_id=:'cid'and journey_purpose='public_hotel:details'and body like'%10 Forest Road%'and body like'%Garden Deluxe%'and body like'%13:00%'and body like'%https://forest.test%'),'hotel-details question immediately after Hi receives configured public information');
select ok(not exists(select 1 from public.messages where conversation_id=:'cid'and direction='out'and(body like'%PRIVATE WIFI%'or body like'%PRIVATE DOOR%'or body like'%Private other address%'or body like'%other.test%')),'public enquiries never disclose stay-only notes or another hotel’s data');
select pg_temp.incoming('919000001481','Can you share hotel details please?','148-details');
select is((select count(*)::integer from public.messages where conversation_id=:'cid'and journey_purpose='public_hotel:details'),1,'duplicate inbound webhook cannot duplicate the answer');
select pg_temp.incoming('919000001481','Where is your resort located?','148-location');
select ok(exists(select 1 from public.messages where conversation_id=:'cid'and journey_purpose='public_hotel:location'and body like'%https://maps.example/forest%'),'location question receives saved address and map');
select pg_temp.incoming('919000001481','What time is check in and check out?','148-hours');
select ok(exists(select 1 from public.messages where conversation_id=:'cid'and journey_purpose='public_hotel:hours'and body like'%13:00%'and body like'%11:30%'),'check-in question replies with configured hotel hours');
select pg_temp.incoming('919000001481','What are your room rates?','148-rates');
select ok(exists(select 1 from public.messages where conversation_id=:'cid'and journey_purpose='public_hotel:rooms'and body like'%5500%'and body like'%indicative%'and body not like'%Inactive hidden room%'),'rates are indicative and exclude room types without active rooms');
select pg_temp.incoming('919000001481','Can you send resort photos?','148-photos');
select is((select count(*)::integer from public.messages where conversation_id=:'cid'and type='image'and guest_reply_to=(select id from public.messages where wa_message_id='148-photos')),2,'natural-language photo request sends actual saved images');
select pg_temp.incoming('919000001481','BOOK','148-book');
select is((select step from private.whatsapp_booking_sessions where conversation_id=:'cid'),'dates','BOOK still starts normal date collection');
select pg_temp.incoming('919000001481','What is your contact number?','148-contact');
select is((select step from private.whatsapp_booking_sessions where conversation_id=:'cid'),'dates','a public question does not reset or consume a booking step');
select pg_temp.incoming('919000001481',to_char((now()at time zone'Asia/Kolkata')::date+1,'DD-MM-YYYY')||' to '||to_char((now()at time zone'Asia/Kolkata')::date+3,'DD-MM-YYYY'),'148-date');
select is((select step from private.whatsapp_booking_sessions where conversation_id=:'cid'),'members','guest can continue the booking after receiving the answer');
select pg_temp.incoming('919000001481','Do you have a pool and parking?','148-facilities');
select ok(exists(select 1 from public.messages where conversation_id=:'cid'and journey_purpose='public_hotel:facilities'and body like'%Reception can confirm%'),'unknown facilities are referred to reception instead of invented');
update public.hotel_message_photos set archived=true where id='e1480000-0000-0000-0000-000000000002';
select ok(private.inbox_delivery_error(:'welcome')is not null,'an archived welcome image is blocked before delivery');
select pg_temp.incoming('919000001482','Hello','148-fallback')as fallback_cid \gset
select ok(exists(select 1 from public.messages where conversation_id=:'fallback_cid'and direction='out'and outbound_payload#>>'{interactive,header,image,link}'='https://forest.test/exterior.jpg'),'welcome falls back to a saved photo when its collage is archived');
update public.hotel_message_photos set archived=true where property_id=:'pid';
select pg_temp.incoming('919000001483','Hello','148-no-photo')as no_photo_cid \gset
select ok(exists(select 1 from public.messages where conversation_id=:'no_photo_cid'and direction='out'and outbound_payload#>'{interactive,header}'is null),'missing photos do not break booking welcome buttons');
update public.conversations set human_handoff=true where id=:'cid';
select pg_temp.incoming('919000001481','hotel details','148-handoff');
select ok(not exists(select 1 from public.messages where guest_reply_to=(select id from public.messages where wa_message_id='148-handoff')),'public answers respect human handling');
update public.conversations set human_handoff=false where id=:'cid';
select pg_temp.incoming('919000001481','STOP','148-stop');
select pg_temp.incoming('919000001481','hotel details','148-stopped');
select ok(not exists(select 1 from public.messages where guest_reply_to=(select id from public.messages where wa_message_id='148-stopped')),'public answers respect STOP');
select ok(not has_function_privilege('authenticated','private.whatsapp_public_hotel_body(uuid,text)','execute'),'public-information helper has no directly exposed browser RPC');
select *from finish();rollback;
