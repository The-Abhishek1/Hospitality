-- Public enquiries use hotel-owned public information; private arrival/stay notes
-- and reservation details are deliberately excluded from these answers.
create function private.whatsapp_public_hotel_intent(p_text text)returns text language plpgsql immutable set search_path=''as $$
declare t text:=lower(regexp_replace(trim(coalesce(p_text,'')),'[[:space:]]+',' ','g'));begin
 if t like'journey:%'or t like'guest:%'or t in('book','book room','book a room','new booking','book another stay','cancel booking enquiry','checkin','check in','check-in','checkout','check out','check-out','reception','human','agent')then return null;end if;
 if t~'\m(photo|photos|picture|pictures|images|gallery)\M'then return 'photos';end if;
 if t~'\m(location|address|directions|located|map|maps)\M'or t~'\mwhere\M.*\m(hotel|resort|property|you)\M'then return 'location';end if;
 if t~'\m(website|web site|homepage)\M'then return 'website';end if;
 if t~'\m(contact|phone|telephone|email|call)\M'then return 'contact';end if;
 if t~'\m(check[ -]?in|check[ -]?out|arrival|departure)\M'and t~'\m(time|times|timing|timings|when|hours|early|late)\M'then return 'hours';end if;
 if t~'\m(rooms|rates|tariff|tariffs|price|prices|pricing|cost|charges|availability|accommodation)\M'or t~'\mroom\M.*\m(type|types|available|rate|rent)\M'then return 'rooms';end if;
 if t~'\m(amenities|facilities|facility|breakfast|parking|pool|wifi|wi-fi|pets|pet|inclusions|included|policies)\M'then return 'facilities';end if;
 if t~'\m(details|information|info)\M'or t~'\m(tell|share|send|about|describe)\M.*\m(hotel|resort|property|stay)\M'then return 'details';end if;
 return null;
end $$;

-- Prefer the hotel's already-generated welcome collage, then a saved hotel photo.
create function private.whatsapp_public_welcome_photo(p_property uuid)returns text language sql stable security definer set search_path=''as $$
 select h.url from public.hotel_message_photos h left join public.whatsapp_default_setup s on s.property_id=h.property_id
 where h.property_id=p_property and not h.archived and private.whatsapp_public_link(h.url)
 order by (h.url is not distinct from s.welcome_image_url)desc,h.created_at,h.id limit 1
$$;

-- Keep the existing welcome text and booking buttons, adding its photo header.
do $$declare d text;needle text:='insert into public.messages(tenant_id,property_id,conversation_id,direction,type,body,status,outbound_payload,guest_reply_to,guest_menu_action,journey_version,journey_reservation,journey_purpose,journey_sender)';begin
 d:=pg_get_functiondef('private.queue_journey_reply(uuid,uuid,text,text,jsonb,uuid)'::regprocedure);
 if strpos(d,needle)=0 then raise exception 'Journey message writer changed.';end if;
 d:=replace(d,needle,E'if p_purpose in(''enquiry_booking'',''enquiry_information'')and p_body like ''Welcome to %''and p_payload#>>''{interactive,type}''=''button''and private.whatsapp_public_welcome_photo(c.property_id)is not null then\n  p_payload:=jsonb_set(p_payload,''{interactive,header}'',jsonb_build_object(''type'',''image'',''image'',jsonb_build_object(''link'',private.whatsapp_public_welcome_photo(c.property_id))));\n end if;\n '||needle);execute d;
end $$;

create function private.whatsapp_public_hotel_body(p_property uuid,p_topic text)returns text language plpgsql stable security definer set search_path=''as $$
declare p public.properties;s public.property_settings;links jsonb;body text;rooms text;destination text;label text;begin
 select *into p from public.properties where id=p_property;select *into s from public.property_settings where property_id=p.id;
 select data into links from public.whatsapp_guest_settings where property_id=p.id;
 body:=left(p.name,180);
 if p_topic in('details','location')then
  body:=body||case when nullif(trim(p.address),'')is not null then E'\nAddress: '||left(p.address,400)else''end||case when nullif(trim(p.city),'')is not null then E'\nCity: '||left(p.city,120)else''end;
  if p_topic='location'and trim(p.address)=''and trim(p.city)=''and coalesce(links->>'maps_url','')=''then body:=body||E'\nOur location is not saved here yet. Reception can share directions.';end if;
 end if;
 if p_topic in('details','contact')then
  body:=body||case when nullif(trim(p.contact_phone),'')is not null then E'\nPhone: '||p.contact_phone else''end||case when nullif(trim(p.contact_email),'')is not null then E'\nEmail: '||p.contact_email else''end;
  if p_topic='contact'and trim(p.contact_phone)=''and trim(p.contact_email)=''then body:=body||E'\nYou can contact reception in this WhatsApp chat. Send RECEPTION for help.';end if;
 end if;
 if p_topic in('details','hours')then
  body:=body||E'\nCheck-in from '||coalesce(to_char(s.check_in_time,'HH24:MI'),'14:00')||'; check-out by '||coalesce(to_char(s.check_out_time,'HH24:MI'),'11:00')||' ('||p.timezone||').';
  if p_topic='hours'then body:=body||E'\nFor early check-in or late check-out, reception must confirm availability.';end if;
 end if;
 if p_topic in('details','rooms')then
  select string_agg(left(x.name,80)||' · up to '||x.max_occupancy||' guests · base '||trim(p.currency)||' '||x.base_rate||' / night',E'\n'order by x.name)into rooms from(select t.name,t.max_occupancy,t.base_rate from public.accommodation_types t where t.property_id=p.id and exists(select 1 from public.accommodation_units u where u.property_id=p.id and u.type_id=t.id and u.active)order by t.name,t.id limit 5)x;
  body:=body||case when rooms is not null then E'\nRoom options (indicative base rates):\n'||rooms||E'\nPrices can change by date, rate plan and guest count. Send BOOK for your exact stay quote and availability.'else E'\nReception can help with room options and prices.'end;
 end if;
 if p_topic='facilities'then body:=body||E'\nReception can confirm facilities, meal inclusions and policies for your stay. Send RECEPTION for a team member. You can also ask for our location, room options or check-in times here.';end if;
 foreach label in array array['maps_url','website_url']loop
  if p_topic='details'or label='maps_url'and p_topic='location'or label='website_url'and p_topic in('website','facilities')then
   destination:=links->>label;
   if private.whatsapp_public_link(destination)and destination!~'/s/'and destination!~*'[?&](token|access_token)='and length(body)+length(destination)<3750 then body:=body||E'\n'||case label when'maps_url'then'Directions: 'else'Website: 'end||destination;
   elsif p_topic='website'and label='website_url'then body:=body||E'\nOur public website is not saved here yet. Reception can help in this chat.';end if;
  end if;
 end loop;
 return body||E'\nSend BOOK to plan a stay, PHOTOS for hotel photos, or RECEPTION to speak with our team.';
end $$;

alter function private.handle_whatsapp_journey(uuid,uuid,text,text)rename to handle_whatsapp_journey_before_public_info;
revoke all on function private.handle_whatsapp_journey_before_public_info(uuid,uuid,text,text)from public,anon,authenticated,service_role;
create function private.handle_whatsapp_journey(p_conversation uuid,p_source uuid,p_command text,p_origin text)returns integer language plpgsql security definer set search_path=''as $$
declare topic text:=private.whatsapp_public_hotel_intent(p_command);c public.conversations;body text;begin
 if topic is null then return private.handle_whatsapp_journey_before_public_info(p_conversation,p_source,p_command,p_origin);end if;
 select *into c from public.conversations where id=p_conversation for update;
 if c.id is null or not private.whatsapp_enquiry(c.id)then return private.handle_whatsapp_journey_before_public_info(p_conversation,p_source,p_command,p_origin);end if;
 if c.human_handoff or c.status<>'open'or c.last_inbound_at is null or c.last_inbound_at<=now()-interval '24 hours'or private.is_opted_out(c.property_id,c.wa_contact_id)or not private.tenant_is_active(c.tenant_id)
 or not exists(select 1 from public.whatsapp_journey_settings where property_id=c.property_id and enabled)
 or exists(select 1 from public.whatsapp_default_setup where property_id=c.property_id and configured_by is not null and not enabled)
 or not exists(select 1 from public.whatsapp_connections w join public.properties p on p.id=w.property_id where w.id=c.connection_id and w.status='active'and p.archived_at is null)
 or not exists(select 1 from public.messages where id=p_source and conversation_id=c.id and direction='in')then return 0;end if;
 if topic='photos'then return private.handle_whatsapp_journey_before_public_info(c.id,p_source,'photos',p_origin);end if;
 body:=private.whatsapp_public_hotel_body(c.property_id,topic);
 perform private.queue_journey_reply(c.id,p_source,'public_hotel:'||topic,body,null);return 1;
end $$;

-- A public question must not be swallowed by the recent-menu debounce, including
-- while dates/name are being collected. Answering never resets the booking session.
do $$declare d text;needle text:='if job.command not like ''journey:%''and job.command not in(';begin
 d:=pg_get_functiondef('public.dispatch_whatsapp_guest_replies(integer,text)'::regprocedure);
 if strpos(d,needle)=0 then raise exception 'Guest reply dispatcher changed.';end if;
 d:=replace(d,needle,'if private.whatsapp_public_hotel_intent(job.command)is null and job.command not like ''journey:%''and job.command not in(');execute d;
end $$;

alter function private.inbox_delivery_error(uuid)rename to inbox_delivery_error_before_public_info;
revoke all on function private.inbox_delivery_error_before_public_info(uuid)from public,anon,authenticated,service_role;
create function private.inbox_delivery_error(p_message uuid)returns text language plpgsql stable security definer set search_path=''as $$
declare why text;m public.messages;photo text;begin
 why:=private.inbox_delivery_error_before_public_info(p_message);if why is not null then return why;end if;
 select *into m from public.messages where id=p_message;
 if m.journey_purpose in('enquiry_booking','enquiry_information')and m.body like'Welcome to %'then
  photo:=m.outbound_payload#>>'{interactive,header,image,link}';
  if photo is not null and not exists(select 1 from public.hotel_message_photos where property_id=m.property_id and url=photo and not archived)then return 'Hotel welcome photo was removed. Send a fresh welcome.';end if;
 end if;return null;
end $$;
revoke all on function private.whatsapp_public_hotel_intent(text),private.whatsapp_public_welcome_photo(uuid),private.whatsapp_public_hotel_body(uuid,text),private.handle_whatsapp_journey(uuid,uuid,text,text),private.inbox_delivery_error(uuid)from public,anon,authenticated,service_role;
