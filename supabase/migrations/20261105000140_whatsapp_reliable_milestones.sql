-- Preserve milestones while provider templates are pending. Native replies are limited
-- to verified contacts, enabled rules and the customer's current service window.
alter table public.whatsapp_automation_events alter column rule_id drop not null;
alter table public.messages add column automation_native boolean not null default false;
create function private.whatsapp_native_event_error(p_event uuid)returns text language plpgsql stable security definer set search_path=''as $$
declare e public.whatsapp_automation_events;r public.reservations;c public.conversations;rule public.whatsapp_automation_rules;cv uuid;st text;begin
 select *into e from public.whatsapp_automation_events where id=p_event;
 if e.id is null or e.expires_at<=now()then return 'Event expired.';end if;
 if not private.tenant_is_active(e.tenant_id)or not exists(select 1 from public.properties where id=e.property_id and archived_at is null)then return 'Hotel account inactive.';end if;
 if not exists(select 1 from public.whatsapp_journey_settings where property_id=e.property_id and enabled)or exists(select 1 from public.whatsapp_default_setup where property_id=e.property_id and configured_by is not null and not enabled)then return 'Guest journey is off.';end if;
 select *into rule from public.whatsapp_automation_rules where property_id=e.property_id and event_key=e.event_key;
 if rule.id is not null and(not rule.enabled or e.rule_id is not null and(rule.id<>e.rule_id or rule.version<>e.rule_version))then return 'Rule paused or changed.';end if;
 if e.event_key not in('booking_confirmed','documents_received','documents_approved','documents_rejected','order_placed','order_preparing','order_ready','order_serving','order_served','order_cancelled','request_received','request_started','request_completed','request_cancelled')then return 'Native event not enabled for this milestone.';end if;
 select *into r from public.reservations where id=e.reservation_id and property_id=e.property_id and guest_id=e.guest_id;
 if r.id is null or r.status in('cancelled','no_show','checked_out')then return 'Stay is no longer eligible.';end if;
 select conversation_id into cv from public.whatsapp_guest_authorizations where property_id=e.property_id and guest_id=e.guest_id and status='granted';
 if cv is null and e.event_key in('booking_confirmed','documents_received','documents_approved','documents_rejected')then select conversation_id into cv from private.whatsapp_booking_contacts where reservation_id=r.id and guest_id=r.guest_id;end if;
 select *into c from public.conversations where id=cv and property_id=e.property_id;
 if c.id is null or c.guest_id is distinct from r.guest_id or c.wa_contact_id is distinct from(select private.campaign_phone(phone)from public.guests where id=r.guest_id)then return 'Guest contact binding changed.';end if;
 if c.human_handoff or c.status<>'open'or private.is_opted_out(e.property_id,c.wa_contact_id)then return 'Guest opted out or conversation handed to reception.';end if;
 if c.last_inbound_at is null or c.last_inbound_at<=now()-interval '24 hours'then return 'Approved template required outside the reply window.';end if;
 if not exists(select 1 from public.whatsapp_connections where id=c.connection_id and status='active'and(e.sender_phone_id is null or e.sender_phone_id=phone_number_id))then return 'Hotel sender is inactive or changed.';end if;
 if e.event_key='documents_approved'and private.journey_document_error(r.id)is not null then return 'Required document review is no longer complete.';end if;
 if e.source_table='orders'then
  select status into st from public.orders where id=e.source_id and property_id=e.property_id and reservation_id=r.id;
  if st is null or st='cancelled'and e.event_key<>'order_cancelled'then return 'Source status changed.';end if;
 elsif e.source_table='guest_documents'then
  select status into st from public.guest_documents where id=e.source_id and property_id=e.property_id and reservation_id=r.id;
  if st is null or e.event_key='documents_received'and st not in('uploaded','clean','image_ready','approved')then return 'Source status changed.';end if;
 elsif e.source_table='guest_requests'then
  select status into st from public.guest_requests where id=e.source_id and property_id=e.property_id and reservation_id=r.id;
  if st is null or st='cancelled'and e.event_key<>'request_cancelled'then return 'Source status changed.';end if;
 end if;return null;
end $$;
revoke all on function private.whatsapp_native_event_error(uuid)from public,anon,authenticated,service_role;

-- Render a compact, purpose-specific receipt. Private document links are only in
-- booking/replacement messages; no generic portal is attached to every update.
create function private.whatsapp_native_event_body(p_event uuid,p_origin text)returns text language plpgsql security definer set search_path=''as $$
declare e public.whatsapp_automation_events;r public.reservations;p public.properties;ref text;body text;cv uuid;begin
 select *into e from public.whatsapp_automation_events where id=p_event;select *into r from public.reservations where id=e.reservation_id;select *into p from public.properties where id=e.property_id;
 ref:=upper(left(replace(r.id::text,'-',''),8));
 body:=case e.event_key
 when'booking_confirmed'then 'Welcome to '||p.name||'! Booking '||ref||' is confirmed. Check-in: '||to_char(r.check_in,'DD-MM-YYYY')||'; check-out: '||to_char(r.check_out,'DD-MM-YYYY')||'. Room total: '||r.total_amount||' '||trim(r.currency)||'.'
 when'documents_received'then 'Your document upload for booking '||ref||' has been received by '||p.name||'. The hotel team will review it and send the result here. Please do not upload it again while review is pending.'
 when'documents_approved'then p.name||' has verified your identity documents. Booking '||ref||': check-in '||to_char(r.check_in,'DD-MM-YYYY')||', check-out '||to_char(r.check_out,'DD-MM-YYYY')||'. Reply CHECK IN when you arrive; your room must be ready.'
 when'documents_rejected'then 'Your document for booking '||ref||' needs a replacement. Please upload a clear photo of the requested identity document.'
 when'order_placed'then p.name||' received food order '||(e.payload->>'order_reference')||'. Our team will take it up and notify you when preparation starts.'
 when'order_preparing'then 'The kitchen at '||p.name||' is preparing food order '||(e.payload->>'order_reference')||'. We will update you when it is ready.'
 when'order_ready'then 'Food order '||(e.payload->>'order_reference')||' at '||p.name||' is ready. Our team will arrange serving or delivery.'
 when'order_serving'then 'Our team is bringing food order '||(e.payload->>'order_reference')||' to you now.'
 when'order_served'then 'Food order '||(e.payload->>'order_reference')||' has been delivered. Enjoy your meal! Send Hi if you need help.'
 when'order_cancelled'then 'Food order '||(e.payload->>'order_reference')||' has been cancelled. Contact reception if you need help.'
 when'request_received'then p.name||' received your request: '||(e.payload->>'request_title')||'. Our team will keep you updated here.'
 when'request_started'then 'Our team is now working on your request: '||(e.payload->>'request_title')||'.'
 when'request_completed'then 'Your request is complete: '||(e.payload->>'request_title')||'. Send Hi if you need anything else.'
 when'request_cancelled'then 'Your request has been cancelled: '||(e.payload->>'request_title')||'. Contact reception for help.'end;
 if e.event_key in('booking_confirmed','documents_rejected')then
  select conversation_id into cv from private.whatsapp_booking_contacts where reservation_id=r.id;
  if cv is null then select conversation_id into cv from public.whatsapp_guest_authorizations where property_id=p.id and guest_id=r.guest_id and status='granted';end if;
  if not private.whatsapp_public_link(p_origin)or p_origin~'[?#]'then return null;end if;
  body:=body||' Upload identity documents securely: '||private.journey_private_link(cv,r.id,'documents',p_origin)||'. Reply Hi to choose WhatsApp stay updates and get help.';
 end if;return body;
end $$;
revoke all on function private.whatsapp_native_event_body(uuid,text)from public,anon,authenticated,service_role;

-- Keep the original provider dispatcher and add a durable native fallback before it.
alter function public.dispatch_whatsapp_automations(integer,text)rename to dispatch_whatsapp_automations_provider;
revoke all on function public.dispatch_whatsapp_automations_provider(integer,text)from public,anon,authenticated,service_role;
create function public.dispatch_whatsapp_automations(p_limit integer default 50,p_portal_origin text default null)returns integer language plpgsql security definer set search_path=''as $$
declare e public.whatsapp_automation_events;rule public.whatsapp_automation_rules;cv uuid;src uuid;body text;mid uuid;sender text;n integer:=0;begin
 for e in select *from public.whatsapp_automation_events where state in('pending','blocked')and due_at<=now()and next_check_at<=now()order by due_at,created_at,id limit greatest(1,least(200,p_limit))for update skip locked loop
  if e.rule_id is null then
   select *into rule from public.whatsapp_automation_rules where property_id=e.property_id and event_key=e.event_key and enabled;
   if rule.id is not null then update public.whatsapp_automation_events set rule_id=rule.id,rule_version=rule.version where id=e.id;e.rule_id:=rule.id;e.rule_version:=rule.version;end if;
  end if;
  -- Prefer the configured template whenever it is ready.
  if e.rule_id is not null and private.whatsapp_automation_error(e.id)is null then continue;end if;
  if private.whatsapp_native_event_error(e.id)is not null then continue;end if;
  select conversation_id into cv from public.whatsapp_guest_authorizations where property_id=e.property_id and guest_id=e.guest_id and status='granted';
  if cv is null then select conversation_id into cv from private.whatsapp_booking_contacts where reservation_id=e.reservation_id and guest_id=e.guest_id;end if;
  body:=private.whatsapp_native_event_body(e.id,p_portal_origin);if body is null then continue;end if;
  select id into src from public.messages where conversation_id=cv and direction='in'order by created_at desc,id desc limit 1;
  mid:=private.queue_journey_reply(cv,src,'milestone:'||e.id::text,body,null,e.reservation_id);
  if mid is null then continue;end if;
  update public.messages set automation_event_id=e.id,automation_native=true where id=mid;
  select phone_number_id into sender from public.whatsapp_connections where id=(select connection_id from public.conversations where id=cv);
  update public.whatsapp_automation_events set state='queued',reason=null,message_id=mid,sender_phone_id=sender where id=e.id;n:=n+1;
 end loop;
 return n+public.dispatch_whatsapp_automations_provider(p_limit,p_portal_origin);
end $$;
revoke all on function public.dispatch_whatsapp_automations(integer,text)from public,anon,authenticated;grant execute on function public.dispatch_whatsapp_automations(integer,text)to service_role;

-- Capture default-pack events even before approval, without re-enabling owner-paused rules.
do $$declare d text;begin
 d:=pg_get_functiondef('private.capture_whatsapp_event(uuid,uuid,text,text,text,uuid,text,jsonb,timestamptz,timestamptz)'::regprocedure);
 d:=replace(d,'if rule.id is null then return;end if;',E'if rule.id is null and (exists(select 1 from public.whatsapp_automation_rules where property_id=p_property and event_key=p_event)or not exists(select 1 from public.whatsapp_default_setup where property_id=p_property and configured_by is not null and enabled)or not exists(select 1 from jsonb_array_elements(private.whatsapp_default_slots())x where x->>''event''=p_event and x->>''activate''=''true''))then return;end if;');
 d:=replace(d,'mins=>rule.delay_minutes','mins=>coalesce(rule.delay_minutes,0)');d:=replace(d,'rule.id,rule.version,payload','rule.id,coalesce(rule.version,0),payload');
 d:=replace(d,'select *into g from public.guests',E'if p_event=''booking_confirmed''then p_dedup:=''welcome:''||r.id;end if;\n if p_event=''documents_received''then p_dedup:=''upload:''||p_source;end if;\n if p_event=''documents_approved''then p_dedup:=''document-review:''||r.id||'':''||(select md5(string_agg(id::text,'',''order by id))from public.guest_documents where reservation_id=r.id and status=''approved'');end if;\n select *into g from public.guests');execute d;
 -- Native event messages must pass the same sender, consent and event checks again at delivery time.
 d:=pg_get_functiondef('private.whatsapp_automation_error(uuid)'::regprocedure);d:=replace(d,'begin',E'begin\n if exists(select 1 from public.messages where automation_event_id=p_event and automation_native)then return private.whatsapp_native_event_error(p_event);end if;');execute d;
end $$;

-- Public photos are useful for both enquiries and booked guests, without revealing a stay.
alter function private.handle_whatsapp_journey(uuid,uuid,text,text)rename to handle_whatsapp_journey_before_photos;
revoke all on function private.handle_whatsapp_journey_before_photos(uuid,uuid,text,text)from public,anon,authenticated,service_role;
create function private.handle_whatsapp_journey(p_conversation uuid,p_source uuid,p_command text,p_origin text)returns integer language plpgsql security definer set search_path=''as $$
declare c public.conversations;p public.properties;photo record;payload jsonb;n integer:=0;begin
 if p_command not in('photos','photo','hotel photos','resort photos','pictures')then return private.handle_whatsapp_journey_before_photos(p_conversation,p_source,p_command,p_origin);end if;
 select *into c from public.conversations where id=p_conversation;select *into p from public.properties where id=c.property_id;
 if c.id is null or c.human_handoff or c.status<>'open'or c.last_inbound_at<=now()-interval '24 hours'or p.archived_at is not null or private.is_opted_out(c.property_id,c.wa_contact_id)or not private.tenant_is_active(c.tenant_id)or not exists(select 1 from public.whatsapp_journey_settings where property_id=p.id and enabled)or exists(select 1 from public.whatsapp_default_setup where property_id=p.id and configured_by is not null and not enabled)or not exists(select 1 from public.messages where id=p_source and conversation_id=c.id and direction='in')or not exists(select 1 from public.whatsapp_connections where id=c.connection_id and status='active')then return 0;end if;
 for photo in select id,url from public.hotel_message_photos where property_id=c.property_id and not archived order by created_at,id limit 4 loop
  if not private.whatsapp_public_link(photo.url)then continue;end if;
  payload:=jsonb_build_object('type','image','image',jsonb_build_object('link',photo.url,'caption',p.name));
  perform private.queue_journey_reply(c.id,p_source,'hotel_photo:'||photo.id,p.name,payload);n:=n+1;
 end loop;
 if n=0 then perform private.queue_journey_reply(c.id,p_source,'hotel_photos_empty','Photos for '||p.name||' are not available yet. Reception can share more information.',null);end if;return greatest(1,n);
end $$;
revoke all on function private.handle_whatsapp_journey(uuid,uuid,text,text)from public,anon,authenticated,service_role;
-- A menu service with an action opens that action directly; it must not send a
-- misleading reception template before opening the actual request chooser.
do $$declare d text;begin
 d:=pg_get_functiondef('private.queue_whatsapp_guest_reply(uuid,uuid,text,boolean,uuid,text)'::regprocedure);
 d:=replace(d,'mid:=private.queue_whatsapp_guest_reply_before_defaults',E'if p_automatic and p_action~''^service:[a-f0-9-]{36}$''then\n select x->>''native_action''into native from public.whatsapp_guest_menu m cross join lateral jsonb_array_elements(m.data->''categories'')k cross join lateral jsonb_array_elements(k->''services'')x where m.property_id=(select property_id from public.conversations where id=p_conversation)and m.enabled and k->>''enabled''=''true''and x->>''enabled''=''true''and x->>''id''=split_part(p_action,'':'',2);\n if native in(''checkin'',''checkout'',''services'',''photos'')then perform private.handle_whatsapp_journey(p_conversation,p_source,native,p_origin);return null;end if;end if;\n mid:=private.queue_whatsapp_guest_reply_before_defaults');execute d;
 d:=pg_get_functiondef('public.dispatch_whatsapp_guest_replies(integer,text)'::regprocedure);d:=replace(d,'''rate food'',''rate service'',''feedback'',''review''','''rate food'',''rate service'',''feedback'',''review'',''photos'',''photo'',''hotel photos'',''resort photos'',''pictures''');execute d;
end $$;
