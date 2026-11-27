-- One date question and one party-size question, followed by room quantities.
alter table private.whatsapp_booking_sessions drop constraint whatsapp_booking_sessions_step_check;
alter table private.whatsapp_booking_sessions add constraint whatsapp_booking_sessions_step_check check(step in('dates','members','room_count','quantity','arrival','departure','guests','name','rooms','confirm','awaiting_payment','booked','cancelled'));
alter table private.whatsapp_booking_sessions alter column step set default 'dates';
alter table private.whatsapp_booking_sessions add column members integer check(members between 1 and 1500),add column room_count integer not null default 1 check(room_count between 1 and 50),add column room_items jsonb not null default '[]'check(jsonb_typeof(room_items)='array'and jsonb_array_length(room_items)<=50),add column group_id uuid references public.reservation_groups(id)on delete set null;

update private.whatsapp_booking_sessions set members=greatest(1,coalesce(adults,0)+coalesce(children,0))where adults is not null;

create function private.enquiry_dates(p_text text)returns date[] language plpgsql immutable set search_path=''as $$
declare token text[];day date;days date[]:='{}';begin
 for token in select regexp_matches(p_text,'\m([0-9]{2}-[0-9]{2}-[0-9]{4}|[0-9]{4}-[0-9]{2}-[0-9]{2})\M','g')loop
  if token[1]~'^[0-9]{4}-'then day:=token[1]::date;else day:=to_date(token[1],'DD-MM-YYYY');if to_char(day,'DD-MM-YYYY')<>token[1]then return null;end if;end if;
  days:=array_append(days,day);
 end loop;
 if cardinality(days)<>2 then return null;end if;return days;
exception when datetime_field_overflow or invalid_datetime_format then return null;
end $$;
create function private.enquiry_room_availability(p_property uuid,p_type uuid,p_in date,p_out date)returns integer language sql stable security definer set search_path=''as $$
 select count(*)::integer from public.accommodation_units u where u.property_id=p_property and u.type_id=p_type and u.active and not exists(select 1 from public.unit_holds h where h.unit_id=u.id and h.active and h.during&&daterange(p_in,p_out,'[)'))
$$;

create function private.enquiry_quote(p_conversation uuid,p_source uuid)returns void language plpgsql security definer set search_path=''as $$
declare s private.whatsapp_booking_sessions;p public.properties;settings public.property_settings;item jsonb;room public.accommodation_types;items jsonb:='[]';capacity integer:=0;remaining integer;left_rooms integer;assigned integer;price numeric;total numeric:=0;summary text:='';body text;begin
 select *into s from private.whatsapp_booking_sessions where conversation_id=p_conversation for update;select *into p from public.properties where id=s.property_id;select *into settings from public.property_settings where property_id=p.id;
 if jsonb_array_length(s.room_items)<>s.room_count then raise exception 'Choose all rooms first.'using errcode='22023';end if;
 for item in select *from jsonb_array_elements(s.room_items)loop select *into room from public.accommodation_types where id=(item->>'type_id')::uuid and property_id=p.id;if room.id is null then raise exception 'Room type changed. Choose rooms again.'using errcode='22023';end if;capacity:=capacity+least(room.max_occupancy,30);end loop;
 if capacity<s.members then raise exception 'The selected rooms hold % members. Choose rooms for all % members.',capacity,s.members using errcode='22023';end if;
 remaining:=s.members;left_rooms:=s.room_count;
 for item in select *from jsonb_array_elements(s.room_items)loop
  select *into room from public.accommodation_types where id=(item->>'type_id')::uuid and property_id=p.id;capacity:=capacity-least(room.max_occupancy,30);
  assigned:=least(least(room.max_occupancy,30),greatest(1,ceil(remaining::numeric/left_rooms)::integer,remaining-capacity));
  price:=private.frontdesk_price(p.id,room.id,s.check_in,s.check_out,assigned,0,s.rate_id);if price<2 then raise exception 'Online bookings require at least INR 2.00 per room.'using errcode='22023';end if;
  items:=items||jsonb_build_array(jsonb_build_object('type_id',room.id,'members',assigned,'quote',price));total:=total+price;remaining:=remaining-assigned;left_rooms:=left_rooms-1;
  if jsonb_array_length(items)<=10 then summary:=summary||E'\n'||jsonb_array_length(items)||'. '||left(room.name,45)||' · '||assigned||' members · '||trim(p.currency)||' '||price;end if;
 end loop;
 update private.whatsapp_booking_sessions set step='confirm',room_items=items,type_id=(items->0->>'type_id')::uuid,quote=total,quote_expires_at=now()+interval '10 minutes',version=version+1 where conversation_id=p_conversation;
 if s.room_count>1 then perform private.queue_journey_reply(p_conversation,p_source,'enquiry_selection','Your room selection:'||summary||case when s.room_count>10 then E'\nPlus '||(s.room_count-10)||' more rooms.'else''end,null);end if;
 body:='Review your booking'||E'\nGuest: '||left(s.guest_name,100)||E'\nCheck-in: '||to_char(s.check_in,'DD-MM-YYYY')||' from '||to_char(settings.check_in_time,'HH24:MI')||E'\nCheck-out: '||to_char(s.check_out,'DD-MM-YYYY')||' by '||to_char(settings.check_out_time,'HH24:MI')||' ('||p.timezone||')'||E'\nMembers: '||s.members||' · Rooms: '||s.room_count||E'\nTotal room price: '||trim(p.currency)||' '||total||E'\n50% deposit: '||trim(p.currency)||' '||(ceil(total*50)/100)||E'\nOne payment link covers all rooms. We hold the rooms for 15 minutes. Booking confirms only after verified payment. By continuing you request payment, confirmation and document-upload instructions in WhatsApp. Stay updates and offers remain optional.';
 perform private.enquiry_reply(p_conversation,p_source,body,private.journey_buttons_payload(body,jsonb_build_array(private.enquiry_button(p_conversation,'enquiry_confirm','Pay 50% to confirm'),private.enquiry_button(p_conversation,'enquiry_start','Change details'),private.enquiry_button(p_conversation,'enquiry_cancel','Cancel enquiry'))));
end $$;

create or replace function private.enquiry_rooms(p_conversation uuid,p_source uuid,p_page integer default 0)returns void language plpgsql security definer set search_path=''as $$
declare s private.whatsapp_booking_sessions;p public.properties;rows jsonb:='[]';item record;total integer;page integer;body text;needed integer;begin
 select *into s from private.whatsapp_booking_sessions where conversation_id=p_conversation;select *into p from public.properties where id=s.property_id;needed:=s.room_count-jsonb_array_length(s.room_items);
 select count(*)into total from public.accommodation_types t where t.property_id=p.id and private.enquiry_room_availability(p.id,t.id,s.check_in,s.check_out)>(select count(*)from jsonb_array_elements(s.room_items)x where x->>'type_id'=t.id::text);
 if total=0 then perform private.enquiry_reply(p_conversation,p_source,'No more rooms are available for those dates. Send BOOK to choose new dates or fewer rooms. No rooms have been booked.');return;end if;
 page:=greatest(0,least(p_page,(total-1)/7));
 for item in select t.id,t.name,t.max_occupancy,t.base_rate,private.enquiry_room_availability(p.id,t.id,s.check_in,s.check_out)-(select count(*)from jsonb_array_elements(s.room_items)x where x->>'type_id'=t.id::text)as available from public.accommodation_types t where t.property_id=p.id and private.enquiry_room_availability(p.id,t.id,s.check_in,s.check_out)>(select count(*)from jsonb_array_elements(s.room_items)x where x->>'type_id'=t.id::text)order by t.name,t.id offset page*7 limit 7 loop
  rows:=rows||jsonb_build_array(private.enquiry_button(p_conversation,'enquiry_room',left(item.name,24),jsonb_build_object('type',item.id))||jsonb_build_object('description',left(item.available||' available · up to '||least(item.max_occupancy,30)||' members per room · base '||trim(p.currency)||' '||item.base_rate||'/night',72)));
 end loop;
 if page>0 then rows:=rows||jsonb_build_array(private.enquiry_button(p_conversation,'enquiry_page','Previous room types',jsonb_build_object('page',page-1)));end if;
 if(page+1)*7<total then rows:=rows||jsonb_build_array(private.enquiry_button(p_conversation,'enquiry_page','More room types',jsonb_build_object('page',page+1)));end if;
 body:='Choose your room type. '||needed||' of '||s.room_count||' room(s) still to select. You can mix room types. The final quote uses your dates and members. Nothing is booked yet.';
 perform private.enquiry_reply(p_conversation,p_source,body,jsonb_build_object('type','interactive','interactive',jsonb_build_object('type','list','body',jsonb_build_object('text',body),'action',jsonb_build_object('button','Choose room type','sections',jsonb_build_array(jsonb_build_object('title','Available rooms','rows',rows))))));
end $$;

create function private.enquiry_add_rooms(p_conversation uuid,p_type uuid,p_quantity integer,p_source uuid)returns void language plpgsql security definer set search_path=''as $$
declare s private.whatsapp_booking_sessions;available integer;begin
 select *into s from private.whatsapp_booking_sessions where conversation_id=p_conversation for update;
 available:=private.enquiry_room_availability(s.property_id,p_type,s.check_in,s.check_out)-(select count(*)from jsonb_array_elements(s.room_items)x where x->>'type_id'=p_type::text);
 if p_quantity is null or p_quantity<1 or p_quantity>available or p_quantity>s.room_count-jsonb_array_length(s.room_items)then raise exception 'Choose a room quantity within current availability.'using errcode='22023';end if;
 update private.whatsapp_booking_sessions set room_items=room_items||(select jsonb_agg(jsonb_build_object('type_id',p_type))from generate_series(1,p_quantity)),step='rooms',version=version+1 where conversation_id=p_conversation returning *into s;
 if jsonb_array_length(s.room_items)=s.room_count then perform private.enquiry_quote(p_conversation,p_source);else perform private.enquiry_rooms(p_conversation,p_source);end if;
end $$;

-- Numeric answers containing “members” or “rooms” belong to the booking wizard.
do $$declare d text;begin
 d:=pg_get_functiondef('private.whatsapp_public_hotel_intent(text)'::regprocedure);d:=replace(d,'if t like''journey:%''',E'if t~''^[0-9]{1,4}([[:space:]]+(members?|people|guests?|rooms?))?[.!?]?$''then return null;end if;\n if t like''journey:%''');execute d;
end $$;
revoke all on function private.enquiry_dates(text),private.enquiry_room_availability(uuid,uuid,date,date),private.enquiry_quote(uuid,uuid),private.enquiry_add_rooms(uuid,uuid,integer,uuid)from public,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION private.handle_whatsapp_journey_before_photos(p_conversation uuid, p_source uuid, p_command text, p_origin text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c public.conversations;p public.properties;s private.whatsapp_booking_sessions;a private.whatsapp_journey_actions;body text;buttons jsonb;raw text;day date;party text[];rid uuid;price numeric;type_name text;start_booking boolean:=false;dates date[];quantity integer;available integer;begin
 select *into c from public.conversations where id=p_conversation for update;
 if c.id is null or c.human_handoff or c.status<>'open'or c.last_inbound_at is null or c.last_inbound_at<now()-interval '24 hours'or private.is_opted_out(c.property_id,c.wa_contact_id)or not private.tenant_is_active(c.tenant_id)
 or not exists(select 1 from public.whatsapp_connections w join public.properties prop on prop.id=w.property_id where w.id=c.connection_id and w.status='active'and prop.archived_at is null)
 or not exists(select 1 from public.whatsapp_journey_settings where property_id=c.property_id and enabled)
 or exists(select 1 from public.whatsapp_default_setup where property_id=c.property_id and configured_by is not null and not enabled)then return 0;end if;
 -- Never accept a fabricated source or a source from another conversation.
 select m.body into raw from public.messages m where m.id=p_source and m.conversation_id=c.id and m.direction='in';if not found then return 0;end if;
 select *into p from public.properties where id=c.property_id;
 select *into s from private.whatsapp_booking_sessions where conversation_id=c.id for update;
 if p_command~'^journey:[a-f0-9-]{36}$'then
  select *into a from private.whatsapp_journey_actions where id=substring(p_command from 9)::uuid for update;
  if a.action like 'enquiry_%'or a.action='post_booking'then
   if a.conversation_id is distinct from c.id or a.phone is distinct from c.wa_contact_id or a.connection_id is distinct from c.connection_id or a.consumed_at is not null then return 0;end if;
   if a.expires_at<=now()or a.settings_version is distinct from(select version from public.whatsapp_journey_settings where property_id=c.property_id)or(a.details?'session'and(a.details->>'session' is distinct from s.id::text or a.details->>'revision' is distinct from s.version::text))then
    perform private.enquiry_reply(c.id,p_source,'This booking option expired or changed. Send BOOK to start again.',null,false);return 1;
   end if;
   update private.whatsapp_journey_actions set consumed_at=clock_timestamp(),source_message_id=p_source where id=a.id;
   start_booking:=a.action in('enquiry_start','post_booking');
  else return private.handle_whatsapp_journey_before_enquiries(c.id,p_source,p_command,p_origin);end if;
 elsif p_command in('book','book room','book a room','new booking','book another stay')then start_booking:=true;
 elsif p_command in('reception','human','agent')then
  return private.handle_whatsapp_journey_before_enquiries(c.id,p_source,p_command,p_origin);
 elsif private.journey_stay(c.id)is not null or exists(select 1 from private.journey_candidate_stays(c.id))then
  return private.handle_whatsapp_journey_before_enquiries(c.id,p_source,p_command,p_origin);
 elsif(s.id is null or s.step in('booked','cancelled')or s.expires_at<=now())and private.poststay_reservation(c.id)is not null then
  return private.handle_whatsapp_journey_before_enquiries(c.id,p_source,p_command,p_origin);
 end if;
 if a.action='enquiry_reception'then
  if s.id is not null then update private.whatsapp_booking_sessions set step='cancelled',version=version+1 where conversation_id=c.id and step<>'booked';end if;
  perform private.queue_journey_reply(c.id,p_source,'handoff','Reception has been notified and will help you book. Automatic replies are paused until reception resumes this chat.',null);
  update public.conversations set human_handoff=true where id=c.id;return 1;
 end if;
 if not private.whatsapp_booking_enabled(p.id)then
  if not private.whatsapp_enquiry(c.id)and not start_booking then return private.handle_whatsapp_journey_before_enquiries(c.id,p_source,p_command,p_origin);end if;
  body:='Welcome to '||left(p.name,180)||'. Please choose Talk to reception for room availability and bookings.';
  perform private.queue_journey_reply(c.id,p_source,'enquiry_information',body,private.journey_buttons_payload(body,jsonb_build_array(private.enquiry_button(c.id,'enquiry_reception','Talk to reception'))));return 1;
 end if;
 if a.action='enquiry_verify'then
  perform private.enquiry_reply(c.id,p_source,'For an existing reservation, use the WhatsApp confirmation from your booking or ask reception to verify your booking and number. No private stay details are shared before verification.',private.journey_buttons_payload('Already booked? Reception can verify your details.',jsonb_build_array(private.enquiry_button(c.id,'enquiry_reception','Talk to reception'))),false);return 1;
 end if;
 if a.action='enquiry_cancel'or p_command='cancel booking enquiry'then
  update private.whatsapp_booking_sessions set step='cancelled',version=version+1 where conversation_id=c.id and step<>'booked';
  perform private.enquiry_reply(c.id,p_source,'Booking enquiry cancelled. No reservation was created or cancelled. Send BOOK whenever you want to start again.',null,false);return 1;
 end if;
 if start_booking then
  if private.journey_stay(c.id)is not null or exists(select 1 from private.journey_candidate_stays(c.id))then return private.handle_whatsapp_journey_before_enquiries(c.id,p_source,'hi',p_origin);end if;
  insert into private.whatsapp_booking_sessions(conversation_id,property_id,connection_id,phone,rate_id)values(c.id,p.id,c.connection_id,c.wa_contact_id,(select default_rate_plan_id from public.property_settings where property_id=p.id))
  on conflict(conversation_id)do update set id=gen_random_uuid(),version=whatsapp_booking_sessions.version+1,step='dates',members=null,room_count=1,room_items='[]',group_id=null,payment_request_id=null,deposit_expires_at=null,check_in=null,check_out=null,adults=null,children=null,guest_name=null,type_id=null,quote=null,quote_expires_at=null,reservation_id=null,connection_id=excluded.connection_id,phone=excluded.phone,rate_id=excluded.rate_id,expires_at=now()+interval '30 minutes';
  perform private.enquiry_reply(c.id,p_source,'Let’s book your stay. What are your check-in and check-out dates? Send both together, for example '||to_char((now()at time zone p.timezone)::date+1,'DD-MM-YYYY')||' to '||to_char((now()at time zone p.timezone)::date+3,'DD-MM-YYYY')||'. Send CANCEL BOOKING ENQUIRY to stop.');return 1;
 end if;
 if s.id is null or s.step in('booked','cancelled')or s.expires_at<=now()then
  if exists(select 1 from public.messages where conversation_id=c.id and direction='out'and journey_purpose='enquiry_booking'and created_at>now()-interval '10 seconds')then return 0;end if;
  body:='Welcome to '||left(p.name,180)||'! Looking for a stay? Check availability and book rooms right here in WhatsApp, or speak with reception.';
  perform private.enquiry_reply(c.id,p_source,body,private.journey_buttons_payload(body,jsonb_build_array(private.journey_button(c.id,null,'enquiry_start','Book rooms'),private.journey_button(c.id,null,'enquiry_verify','Already booked'),private.journey_button(c.id,null,'enquiry_reception','Talk to reception'))),false);return 1;
 end if;
 if s.connection_id<>c.connection_id or s.phone<>c.wa_contact_id then return 0;end if;
 if a.action='enquiry_page'and s.step='rooms'then perform private.enquiry_rooms(c.id,p_source,(a.details->>'page')::integer);return 1;end if;
 if a.action='enquiry_room'and s.step='rooms'then
  select name into type_name from public.accommodation_types where id=(a.details->>'type')::uuid and property_id=p.id;
  available:=least(s.room_count-jsonb_array_length(s.room_items),private.enquiry_room_availability(p.id,(a.details->>'type')::uuid,s.check_in,s.check_out)-(select count(*)from jsonb_array_elements(s.room_items)x where x->>'type_id'=a.details->>'type'));
  if type_name is null or available<1 then perform private.enquiry_rooms(c.id,p_source);return 1;end if;
  if s.room_count=1 then
   begin perform private.enquiry_add_rooms(c.id,(a.details->>'type')::uuid,1,p_source);
   exception when sqlstate '22023'then update private.whatsapp_booking_sessions set room_items='[]',step='rooms',version=version+1 where conversation_id=c.id;perform private.enquiry_reply(c.id,p_source,left(sqlerrm,400)||' Send ROOMS to choose again.');end;
  else
   update private.whatsapp_booking_sessions set type_id=(a.details->>'type')::uuid,step='quantity',version=version+1 where conversation_id=c.id;
   perform private.enquiry_reply(c.id,p_source,'How many '||left(type_name,100)||' rooms would you like? Send a number from 1 to '||available||'.');
  end if;return 1;
 end if;
 if a.action='enquiry_confirm'and s.step='confirm'then
  begin rid:=private.confirm_enquiry_booking(c.id,p_source);
  exception when sqlstate 'P0002'or sqlstate '23P01'or sqlstate '22023'then
   body:=left(sqlerrm,300)||' No booking was created. Choose Change details for a fresh quote, or ask reception.';
   update private.whatsapp_booking_sessions set step='rooms',version=version+1 where conversation_id=c.id;
   perform private.enquiry_reply(c.id,p_source,body,private.journey_buttons_payload(body,jsonb_build_array(private.enquiry_button(c.id,'enquiry_start','Change details'),private.enquiry_button(c.id,'enquiry_reception','Talk to reception'))));return 1;
  end;
  body:='Your selected room(s) are held for 15 minutes while we prepare one secure 50% deposit link for the booking total. The booking is not confirmed until payment is verified.';
  perform private.queue_journey_reply(c.id,p_source,'deposit_preparing',body,null,null);return 1;
 end if;
 if s.step='dates'then
  dates:=private.enquiry_dates(raw);
  if dates is null or dates[1]<(now()at time zone p.timezone)::date or dates[1]>(now()at time zone p.timezone)::date+730 or dates[2]-dates[1]not between 1 and 30 then
   perform private.enquiry_reply(c.id,p_source,'Please send both dates as DD-MM-YYYY to DD-MM-YYYY. Check-out must follow check-in; choose a stay of 1–30 nights.');return 1;
  end if;
  update private.whatsapp_booking_sessions set check_in=dates[1],check_out=dates[2],step='members',version=version+1 where conversation_id=c.id;
  body:='How many members will be staying? Send the total number, for example 6.';
 elsif s.step in('arrival','departure')then
  -- Existing sessions can finish their already-requested date before using the new questions.
  dates:=private.enquiry_dates(raw);
  begin day:=case when trim(raw)~'^[0-9]{4}-'then trim(raw)::date else to_date(trim(raw),'DD-MM-YYYY')end;if trim(raw)!~'^[0-9]{4}-'and to_char(day,'DD-MM-YYYY')<>trim(raw)then raise exception 'invalid';end if;
  exception when others then perform private.enquiry_reply(c.id,p_source,'Please send a valid date as DD-MM-YYYY.');return 1;end;
  if day<(now()at time zone p.timezone)::date or day>(now()at time zone p.timezone)::date+730 or s.step='departure'and(day<=s.check_in or day-s.check_in>30)then perform private.enquiry_reply(c.id,p_source,'Choose upcoming check-in and check-out dates for 1–30 nights.');return 1;end if;
  if s.step='arrival'then update private.whatsapp_booking_sessions set check_in=day,step='departure',version=version+1 where conversation_id=c.id;body:='What is your check-out date? Send DD-MM-YYYY.';
  else update private.whatsapp_booking_sessions set check_out=day,step='members',version=version+1 where conversation_id=c.id;body:='How many members will be staying? Send the total number.';end if;
 elsif s.step in('members','guests')then
  party:=regexp_match(lower(trim(raw)),'^([1-9][0-9]{0,3})(?:[[:space:]]+(?:members?|people|guests?))?$');
  if party is null or party[1]::integer>1500 then perform private.enquiry_reply(c.id,p_source,'How many members? Send a number from 1 to 1500.');return 1;end if;
  update private.whatsapp_booking_sessions set members=party[1]::integer,adults=party[1]::integer,children=0,step='room_count',version=version+1 where conversation_id=c.id;
  body:='How many rooms would you like to book? Send 1 for a single room, or a number up to '||least(50,party[1]::integer)||' for a group booking. You can mix room types.';
 elsif s.step='room_count'then
  party:=regexp_match(lower(trim(raw)),'^([1-9][0-9]?)(?:[[:space:]]+rooms?)?$');
  if party is null or party[1]::integer>least(50,s.members)then perform private.enquiry_reply(c.id,p_source,'Choose 1–'||least(50,s.members)||' rooms, with at least one member per room.');return 1;end if;
  if party[1]::integer>(select count(*)from public.accommodation_units u where u.property_id=p.id and u.active and not exists(select 1 from public.unit_holds h where h.unit_id=u.id and h.active and h.during&&daterange(s.check_in,s.check_out,'[)')))then perform private.enquiry_reply(c.id,p_source,'There are not enough rooms for those dates. Choose fewer rooms, or send BOOK to change dates.');return 1;end if;
  update private.whatsapp_booking_sessions set room_count=party[1]::integer,step='name',version=version+1 where conversation_id=c.id;
  body:='What is the full name of the booking contact? Send the name as it appears on their identity document.';
 elsif s.step='quantity'then
  party:=regexp_match(lower(trim(raw)),'^([1-9][0-9]?)(?:[[:space:]]+rooms?)?$');
  begin
   if party is null then raise exception 'Send a valid room quantity.'using errcode='22023';end if;
   perform private.enquiry_add_rooms(c.id,s.type_id,party[1]::integer,p_source);
  exception when sqlstate '22023'then
   update private.whatsapp_booking_sessions set room_items='[]',step='rooms',version=version+1 where conversation_id=c.id;
   perform private.enquiry_reply(c.id,p_source,left(sqlerrm,400)||' Send ROOMS to choose room types again.');
  end;return 1;
 elsif s.step='name'then
  if length(trim(coalesce(raw,'')))not between 2 and 120 or raw~'[[:cntrl:]]'then perform private.enquiry_reply(c.id,p_source,'Please send the guest’s full name using 2–120 characters.');return 1;end if;
  update private.whatsapp_booking_sessions set guest_name=trim(raw),step='rooms',version=version+1 where conversation_id=c.id;perform private.enquiry_rooms(c.id,p_source);return 1;
 elsif s.step='rooms'then perform private.enquiry_rooms(c.id,p_source);return 1;
 else body:='Use Confirm booking above to accept the quote, or send BOOK to start again. No reservation is created by a text reply.';end if;
 perform private.enquiry_reply(c.id,p_source,body);return 1;
end $function$;

-- A contact name can contain words such as “Contact”, “Rates” or “Garden”.
-- During the name answer, do not reinterpret it as a public hotel question.
do $$declare d text;begin
 d:=pg_get_functiondef('private.handle_whatsapp_journey(uuid,uuid,text,text)'::regprocedure);
 d:=replace(d,'if topic is null then','if topic is null or exists(select 1 from private.whatsapp_booking_sessions where conversation_id=p_conversation and step=''name''and expires_at>now())then');execute d;
end $$;
