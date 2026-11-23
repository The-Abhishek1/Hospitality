-- Resource reuse, isolation and stale-menu protection. All writes roll back.
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

insert into public.hotel_message_photos(id,property_id,name,url,mime_type)values
 ('f1000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','Hotel A photo','https://assets.example.test/a.jpg','image/jpeg'),
 ('f1000000-0000-0000-0000-000000000002','e3000000-0000-0000-0000-000000000002','Hotel B photo','https://assets.example.test/b.jpg','image/jpeg');
insert into public.message_templates(id,tenant_id,property_id,name,language,category,status,body,provider_definition)values
 ('f2000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','directions_snapshot','en_US','utility','approved','Find our hotel using the directions button.', '{"components":[{"type":"BUTTONS","buttons":[{"type":"URL","text":"Directions","url":"https://maps.google.com/original"}]}]}');
insert into public.whatsapp_template_assets(property_id,provider_template_id,image_url)values('e3000000-0000-0000-0000-000000000001','existing-header','https://assets.example.test/a.jpg');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"e1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is((public.hotel_message_resources('e3000000-0000-0000-0000-000000000001')->>'version')::integer,0,'New hotel information starts at version zero');
select is(jsonb_array_length(public.hotel_message_resources('e3000000-0000-0000-0000-000000000001')->'photos'),1,'Resource library contains only this hotel photos');
select is((select count(*)::integer from public.hotel_message_photos),1,'Photo metadata RLS isolates hotels');
select throws_ok($$select public.hotel_message_resources('e3000000-0000-0000-0000-000000000002')$$,'42501',null,'Cannot read another hotel resources');
select throws_ok($$select public.save_hotel_message_links('e3000000-0000-0000-0000-000000000002',0,'{"maps_url":"","review_url":"","website_url":""}','Set links')$$,'42501',null,'Cannot edit another hotel links');
select throws_ok($$insert into public.hotel_message_photos(property_id,name,url)values('e3000000-0000-0000-0000-000000000001','Unvalidated','https://other.test/image')$$,'42501',null,'Clients cannot register unvalidated upload metadata directly');
select is(public.save_hotel_message_links('e3000000-0000-0000-0000-000000000001',0,'{"maps_url":"https://maps.google.com/original","review_url":"https://hotel.test/review","website_url":"https://hotel.test"}','Set hotel destinations'),1,'Owner saves shared links independently');
select is(public.hotel_message_resources('e3000000-0000-0000-0000-000000000001')#>>'{links,review_url}','https://hotel.test/review','Resources return saved review destination');
select throws_ok($$select public.save_hotel_message_links('e3000000-0000-0000-0000-000000000001',0,'{"maps_url":"","review_url":"","website_url":""}','Set links')$$,'40001',null,'Stale hotel information form cannot overwrite changes');
select throws_ok($$select public.save_hotel_message_links('e3000000-0000-0000-0000-000000000001',1,'{"maps_url":"http://example.com","review_url":"","website_url":""}','Set links')$$,'22023',null,'Insecure shared links rejected');
select throws_ok($$select public.save_hotel_message_links('e3000000-0000-0000-0000-000000000001',1,'{"maps_url":"https://hotel.test/s/private-token","review_url":"","website_url":""}','Set links')$$,'22023',null,'Private guest tokens cannot become shared destinations');
select throws_ok($$select public.save_hotel_message_links('e3000000-0000-0000-0000-000000000001',1,'{"maps_url":"https://hotel.test/?token=private","review_url":"","website_url":""}','Set links')$$,'22023',null,'Token query destinations cannot become shared links');
select throws_ok($$select public.save_hotel_message_links('e3000000-0000-0000-0000-000000000001',1,'{"maps_url":"","review_url":null,"website_url":""}','Set links')$$,'22023',null,'Null shared fields cannot bypass validation');
select set_config('test.resources_menu','{"intro":"Welcome. Choose a service.","items":[{"action":"stay","label":"Stay","enabled":false}],"maps_url":"https://maps.google.com/stale","review_url":"https://hotel.test/stale","website_url":"https://hotel.test/stale","photos":[],"categories":[{"id":"10000000-0000-4000-8000-000000000001","label":"My stay","enabled":true,"services":[]}]}',true);
select lives_ok($$select public.save_whatsapp_guest_menu('e3000000-0000-0000-0000-000000000001',0,false,current_setting('test.resources_menu')::jsonb)$$,'Menu saves independently of shared links');
select is(public.hotel_message_resources('e3000000-0000-0000-0000-000000000001')#>>'{links,maps_url}','https://maps.google.com/original','Menu draft cannot replace shared hotel location');
select is((public.hotel_message_resources('e3000000-0000-0000-0000-000000000001')->>'version')::integer,1,'Menu save does not invalidate hotel information version');
select is((select data->>'maps_url'from public.whatsapp_guest_menu where property_id='e3000000-0000-0000-0000-000000000001'),'https://maps.google.com/original','Stored menu uses current canonical destinations');
select is(public.save_hotel_message_links('e3000000-0000-0000-0000-000000000001',1,'{"maps_url":"https://maps.google.com/updated","review_url":"https://hotel.test/new-review","website_url":"https://hotel.test"}','Updated hotel destinations'),2,'Owner updates links without publishing menus');
select is((select version from public.whatsapp_guest_menu where property_id='e3000000-0000-0000-0000-000000000001'),1,'Shared link changes leave grouped-menu version intact');
select is((select enabled from public.whatsapp_guest_menu where property_id='e3000000-0000-0000-0000-000000000001'),false,'Saving hotel information never activates a menu');
select is((select provider_definition#>>'{components,0,buttons,0,url}'from public.message_templates where id='f2000000-0000-0000-0000-000000000001'),'https://maps.google.com/original','Existing template button URL is preserved');
select lives_ok($$select public.save_whatsapp_guest_menu('e3000000-0000-0000-0000-000000000001',1,false,current_setting('test.resources_menu')::jsonb)$$,'Older open menu draft can save its own menu changes');
select is(public.hotel_message_resources('e3000000-0000-0000-0000-000000000001')#>>'{links,review_url}','https://hotel.test/new-review','Older menu draft cannot undo a newly saved review destination');
select throws_ok($$select public.archive_hotel_message_photo('e3000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000002')$$,'22023',null,'Cannot archive a different hotel photo');
select lives_ok($$select public.archive_hotel_message_photo('e3000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001')$$,'Owner can remove photo from reusable library');
select is(jsonb_array_length(public.hotel_message_resources('e3000000-0000-0000-0000-000000000001')->'photos'),0,'Archived photo is hidden from picker');
select is((select count(*)::integer from public.hotel_message_photos where id='f1000000-0000-0000-0000-000000000001'),1,'Archiving keeps photo metadata and file references');
select is((select image_url from public.whatsapp_template_assets where provider_template_id='existing-header'),'https://assets.example.test/a.jpg','Existing template delivery image remains intact');
select is((select count(*)::integer from public.property_settings_events where property_id='e3000000-0000-0000-0000-000000000001'and section='information'),2,'Shared link updates have property change history');
reset role;
select is((select count(*)::integer from public.messages where property_id='e3000000-0000-0000-0000-000000000001'),0,'Configuring hotel resources sends no guest message');
set local role anon;
select throws_ok($$select public.hotel_message_resources('e3000000-0000-0000-0000-000000000001')$$,'42501',null,'Anonymous clients cannot access hotel resource library');
reset role;
select *from finish();
rollback;
