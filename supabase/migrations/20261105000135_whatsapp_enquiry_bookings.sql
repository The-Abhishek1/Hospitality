-- Guest-initiated room bookings use the existing authenticated inbound queue,
-- nightly pricing and exclusion-protected room allocation. No public booking RPC.
alter table public.reservations add column booking_origin text check(booking_origin is null or booking_origin='whatsapp');
create index reservations_guest_property on public.reservations(guest_id,property_id);
alter table private.whatsapp_booking_contacts alter column actor_id drop not null;
create table public.whatsapp_booking_settings(
 property_id uuid primary key references public.properties(id)on delete cascade,
 enabled boolean not null default true,version integer not null default 1
);
alter table public.whatsapp_booking_settings enable row level security;
revoke all on public.whatsapp_booking_settings from public,anon,authenticated,service_role;
create function public.whatsapp_booking_workspace(p_property uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel administrator access required.'using errcode='42501';end if;
 return coalesce((select to_jsonb(s)from public.whatsapp_booking_settings s where property_id=p_property),jsonb_build_object('enabled',true,'version',0));
end $$;
create function public.save_whatsapp_booking_settings(p_property uuid,p_version integer,p_enabled boolean)returns void language plpgsql security definer set search_path=''as $$begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel administrator access required.'using errcode='42501';end if;
 perform 1 from public.properties where id=p_property for update;perform private.staff_share(p_property);
 if p_enabled is null or coalesce((select version from public.whatsapp_booking_settings where property_id=p_property),0)is distinct from p_version then raise exception 'Booking settings changed. Refresh and try again.'using errcode='40001';end if;
 insert into public.whatsapp_booking_settings(property_id,enabled)values(p_property,p_enabled)on conflict(property_id)do update set enabled=excluded.enabled,version=whatsapp_booking_settings.version+1;
 insert into public.whatsapp_automation_audit(property_id,tenant_id,actor,action,details)select p_property,tenant_id,auth.uid(),'booking_preference',jsonb_build_object('enabled',p_enabled)from public.properties where id=p_property;
end $$;
revoke all on function public.whatsapp_booking_workspace(uuid),public.save_whatsapp_booking_settings(uuid,integer,boolean)from public,anon;
grant execute on function public.whatsapp_booking_workspace(uuid),public.save_whatsapp_booking_settings(uuid,integer,boolean)to authenticated;

create table private.whatsapp_booking_sessions(
 conversation_id uuid primary key references public.conversations(id)on delete cascade,
 id uuid not null unique default gen_random_uuid(),property_id uuid not null references public.properties(id)on delete cascade,
 connection_id uuid not null references public.whatsapp_connections(id)on delete cascade,phone text not null,
 version integer not null default 1,step text not null default 'arrival'check(step in('arrival','departure','guests','name','rooms','confirm','booked','cancelled')),
 check_in date,check_out date,adults integer,children integer,guest_name text,
 type_id uuid,rate_id uuid,quote numeric,quote_expires_at timestamptz,
 reservation_id uuid references public.reservations(id)on delete cascade,
 expires_at timestamptz not null default(now()+interval '30 minutes')
);
revoke all on private.whatsapp_booking_sessions from public,anon,authenticated,service_role;
alter table public.messages add column enquiry_session uuid,add column enquiry_revision integer;

create function private.whatsapp_booking_enabled(p_property uuid)returns boolean language sql stable security definer set search_path=''as $$
 select coalesce((select enabled from public.whatsapp_booking_settings where property_id=p_property),true)
$$;
create function private.whatsapp_enquiry(p_conversation uuid)returns boolean language sql stable security definer set search_path=''as $$
 select not exists(select 1 from public.conversations c join public.reservations r on r.guest_id=c.guest_id and r.property_id=c.property_id where c.id=p_conversation)
$$;
create function private.enquiry_button(p_conversation uuid,p_action text,p_title text,p_extra jsonb default '{}')returns jsonb language sql volatile security definer set search_path=''as $$
 select private.journey_button(p_conversation,null,p_action,p_title,coalesce((select jsonb_build_object('session',id,'revision',version)from private.whatsapp_booking_sessions where conversation_id=p_conversation),'{}')||p_extra)
$$;
create function private.enquiry_reply(p_conversation uuid,p_source uuid,p_body text,p_payload jsonb default null,p_bind boolean default true)returns void language plpgsql security definer set search_path=''as $$declare mid uuid;begin
 mid:=private.queue_journey_reply(p_conversation,p_source,'enquiry_booking',p_body,p_payload);
 if p_bind then update public.messages m set enquiry_session=s.id,enquiry_revision=s.version from private.whatsapp_booking_sessions s where m.id=mid and s.conversation_id=p_conversation;end if;
end $$;
create function private.enquiry_rooms(p_conversation uuid,p_source uuid,p_page integer default 0)returns void language plpgsql security definer set search_path=''as $$
declare s private.whatsapp_booking_sessions;p public.properties;rows jsonb:='[]';item record;total integer;page integer;body text;begin
 select *into s from private.whatsapp_booking_sessions where conversation_id=p_conversation;
 select *into p from public.properties where id=s.property_id;
 select count(*)into total from public.accommodation_types t where t.property_id=p.id and t.max_occupancy>=s.adults+s.children and exists(select 1 from public.accommodation_units u where u.type_id=t.id and u.property_id=p.id and u.active and not exists(select 1 from public.unit_holds h where h.unit_id=u.id and h.active and h.during&&daterange(s.check_in,s.check_out,'[)')));
 if total=0 then
  body:='No rooms are available for '||s.check_in||' to '||s.check_out||' for your party. Choose different dates or ask reception about more rooms.';
  perform private.enquiry_reply(p_conversation,p_source,body,private.journey_buttons_payload(body,jsonb_build_array(private.enquiry_button(p_conversation,'enquiry_start','Change dates'),private.enquiry_button(p_conversation,'enquiry_reception','Talk to reception'))));return;
 end if;
 page:=greatest(0,least(coalesce(p_page,0),(total-1)/7));
 for item in select t.id,t.name,private.frontdesk_price(p.id,t.id,s.check_in,s.check_out,s.adults,s.children,s.rate_id)as price from public.accommodation_types t where t.property_id=p.id and t.max_occupancy>=s.adults+s.children and exists(select 1 from public.accommodation_units u where u.type_id=t.id and u.property_id=p.id and u.active and not exists(select 1 from public.unit_holds h where h.unit_id=u.id and h.active and h.during&&daterange(s.check_in,s.check_out,'[)')))order by t.name,t.id offset page*7 limit 7 loop
  rows:=rows||jsonb_build_array(private.enquiry_button(p_conversation,'enquiry_room',left(item.name,24),jsonb_build_object('type',item.id))||jsonb_build_object('description',left(trim(p.currency)||' '||item.price||' total · '||(s.check_out-s.check_in)||' night(s)',72)));
 end loop;
 if page>0 then rows:=rows||jsonb_build_array(private.enquiry_button(p_conversation,'enquiry_page','Previous rooms',jsonb_build_object('page',page-1)));end if;
 if(page+1)*7<total then rows:=rows||jsonb_build_array(private.enquiry_button(p_conversation,'enquiry_page','More rooms',jsonb_build_object('page',page+1)));end if;
 rows:=rows||jsonb_build_array(private.enquiry_button(p_conversation,'enquiry_cancel','Cancel enquiry'));
 body:='Available rooms at '||left(p.name,180)||' · '||s.check_in||' to '||s.check_out||'. Prices cover one room for the full stay, before extras. Nothing is booked until you confirm.';
 perform private.enquiry_reply(p_conversation,p_source,body,jsonb_build_object('type','interactive','interactive',jsonb_build_object('type','list','body',jsonb_build_object('text',body),'action',jsonb_build_object('button','Choose a room','sections',jsonb_build_array(jsonb_build_object('title','Available rooms','rows',rows))))));
end $$;

-- The guest confirms one exact quote. Any failure rolls back the guest, booking,
-- contact proof and allocation together; the unit exclusion remains authoritative.
create function private.confirm_enquiry_booking(p_conversation uuid,p_source uuid)returns uuid language plpgsql security definer set search_path=''as $$
declare s private.whatsapp_booking_sessions;c public.conversations;p public.properties;gid uuid;rid uuid;unit uuid;price numeric;begin
 select *into c from public.conversations where id=p_conversation for update;
 select *into s from private.whatsapp_booking_sessions where conversation_id=c.id for update;
 select *into p from public.properties where id=c.property_id for update;
 if s.reservation_id is not null then return s.reservation_id;end if;
 if s.step<>'confirm'or s.expires_at<=now()or s.quote_expires_at<=now()or s.connection_id<>c.connection_id or s.phone<>c.wa_contact_id or not private.whatsapp_booking_enabled(p.id)then raise exception 'Your booking quote expired. Choose a room again.'using errcode='22023';end if;
 if s.check_in<(now()at time zone p.timezone)::date then raise exception 'Arrival date has passed. Start again with new dates.'using errcode='22023';end if;
 price:=private.frontdesk_price(p.id,s.type_id,s.check_in,s.check_out,s.adults,s.children,s.rate_id);
 if price is distinct from s.quote or s.rate_id is distinct from(select default_rate_plan_id from public.property_settings where property_id=p.id)then raise exception 'The room price changed. Review a fresh quote before confirming.'using errcode='22023';end if;
 if c.guest_id is not null then
  select g.id into gid from public.guests g where g.id=c.guest_id and g.tenant_id=c.tenant_id and private.campaign_phone(g.phone)=c.wa_contact_id and lower(trim(g.full_name))=lower(trim(s.guest_name));
  if gid is null then raise exception 'This number is linked to another guest profile. Reception can help with a booking for someone else.'using errcode='22023';end if;
 else
  if exists(select 1 from public.whatsapp_guest_authorizations where property_id=p.id and wa_contact_id=c.wa_contact_id)or exists(select 1 from public.guests g join public.reservations r on r.guest_id=g.id and r.property_id=p.id where private.campaign_phone(g.phone)=c.wa_contact_id)then raise exception 'Reception needs to verify the existing guest profile for this number before booking.'using errcode='22023';end if;
  insert into public.guests(tenant_id,full_name,phone)values(p.tenant_id,s.guest_name,'+'||c.wa_contact_id)returning id into gid;
 end if;
 insert into public.reservations(tenant_id,property_id,guest_id,source,booking_origin,check_in,check_out,adults,children,rate_plan_id,total_amount,currency,creation_request_id,notes)
 values(p.tenant_id,p.id,gid,'direct','whatsapp',s.check_in,s.check_out,s.adults,s.children,s.rate_id,price,p.currency,s.id,'Guest confirmed this booking in WhatsApp.')returning id into rid;
 unit:=private.frontdesk_allocate(p.id,p.tenant_id,s.type_id,s.check_in,s.check_out,rid,null);
 update public.conversations set guest_id=gid,contact_name=s.guest_name where id=c.id;
 insert into private.whatsapp_booking_contacts(reservation_id,property_id,guest_id,conversation_id,phone,evidence,actor_id)values(rid,p.id,gid,c.id,c.wa_contact_id,'Guest explicitly confirmed the quoted booking and requested its confirmation and document link in WhatsApp. Source message: '||p_source,null);
 insert into public.reservation_events(tenant_id,property_id,reservation_id,event_type,details)values(p.tenant_id,p.id,rid,'created',jsonb_build_object('source','whatsapp','unit_id',unit,'source_message',p_source,'session',s.id));
 update private.whatsapp_booking_sessions set step='booked',reservation_id=rid,version=version+1 where conversation_id=c.id;
 update public.whatsapp_automation_events set next_check_at=now()where reservation_id=rid and event_key='booking_confirmed'and state in('pending','blocked');
 perform private.wake_whatsapp_guest_worker();return rid;
end $$;

alter function private.handle_whatsapp_journey(uuid,uuid,text,text)rename to handle_whatsapp_journey_before_enquiries;
revoke all on function private.handle_whatsapp_journey_before_enquiries(uuid,uuid,text,text)from public,anon,authenticated,service_role;
create function private.handle_whatsapp_journey(p_conversation uuid,p_source uuid,p_command text,p_origin text)returns integer language plpgsql security definer set search_path=''as $$
declare c public.conversations;p public.properties;s private.whatsapp_booking_sessions;a private.whatsapp_journey_actions;body text;buttons jsonb;raw text;day date;party text[];rid uuid;price numeric;type_name text;start_booking boolean:=false;begin
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
  on conflict(conversation_id)do update set id=gen_random_uuid(),version=whatsapp_booking_sessions.version+1,step='arrival',check_in=null,check_out=null,adults=null,children=null,guest_name=null,type_id=null,quote=null,quote_expires_at=null,reservation_id=null,connection_id=excluded.connection_id,phone=excluded.phone,rate_id=excluded.rate_id,expires_at=now()+interval '30 minutes';
  perform private.enquiry_reply(c.id,p_source,'Let’s book one room at '||left(p.name,180)||'. What is your arrival date? Send YYYY-MM-DD, for example '||((now()at time zone p.timezone)::date+1)||'. Send CANCEL BOOKING ENQUIRY to stop. For groups, send RECEPTION.');return 1;
 end if;
 if s.id is null or s.step in('booked','cancelled')or s.expires_at<=now()then
  if exists(select 1 from public.messages where conversation_id=c.id and direction='out'and journey_purpose='enquiry_booking'and created_at>now()-interval '10 seconds')then return 0;end if;
  body:='Welcome to '||left(p.name,180)||'! Looking for a stay? Check availability and book a room right here in WhatsApp, or speak with reception.';
  perform private.enquiry_reply(c.id,p_source,body,private.journey_buttons_payload(body,jsonb_build_array(private.journey_button(c.id,null,'enquiry_start','Book a room'),private.journey_button(c.id,null,'enquiry_verify','Already booked'),private.journey_button(c.id,null,'enquiry_reception','Talk to reception'))),false);return 1;
 end if;
 if s.connection_id<>c.connection_id or s.phone<>c.wa_contact_id then return 0;end if;
 if a.action='enquiry_page'and s.step='rooms'then perform private.enquiry_rooms(c.id,p_source,(a.details->>'page')::integer);return 1;end if;
 if a.action='enquiry_room'and s.step='rooms'then
  select t.name,private.frontdesk_price(p.id,t.id,s.check_in,s.check_out,s.adults,s.children,s.rate_id)into type_name,price from public.accommodation_types t where t.id=(a.details->>'type')::uuid and t.property_id=p.id;
  if type_name is null then perform private.enquiry_rooms(c.id,p_source);return 1;end if;
  update private.whatsapp_booking_sessions set step='confirm',type_id=(a.details->>'type')::uuid,quote=price,quote_expires_at=now()+interval '10 minutes',expires_at=now()+interval '30 minutes',version=version+1 where conversation_id=c.id;
  body:='Review your booking at '||left(p.name,180)||E'\nGuest: '||s.guest_name||E'\nRoom: '||left(type_name,120)||E'\nArrival: '||s.check_in||E'\nDeparture: '||s.check_out||E'\nGuests: '||s.adults||' adult(s), '||s.children||E' child(ren)\nRoom total before extras: '||trim(p.currency)||' '||price||E'\nNo payment is collected in this chat. By confirming you request this booking, its WhatsApp confirmation and secure document-upload link. Ongoing updates and offers are separate choices. Quote valid for 10 minutes; availability is rechecked.';
  perform private.enquiry_reply(c.id,p_source,body,private.journey_buttons_payload(body,jsonb_build_array(private.enquiry_button(c.id,'enquiry_confirm','Confirm booking'),private.enquiry_button(c.id,'enquiry_start','Change details'),private.enquiry_button(c.id,'enquiry_cancel','Cancel enquiry'))));return 1;
 end if;
 if a.action='enquiry_confirm'and s.step='confirm'then
  begin rid:=private.confirm_enquiry_booking(c.id,p_source);
  exception when sqlstate 'P0002'or sqlstate '23P01'or sqlstate '22023'then
   body:=left(sqlerrm,300)||' No booking was created. Choose Change details for a fresh quote, or ask reception.';
   update private.whatsapp_booking_sessions set step='rooms',version=version+1 where conversation_id=c.id;
   perform private.enquiry_reply(c.id,p_source,body,private.journey_buttons_payload(body,jsonb_build_array(private.enquiry_button(c.id,'enquiry_start','Change details'),private.enquiry_button(c.id,'enquiry_reception','Talk to reception'))));return 1;
  end;
  body:='Booking confirmed at '||left(p.name,180)||'! Reference: '||upper(left(replace(rid::text,'-',''),8))||'. Arrival '||s.check_in||'; departure '||s.check_out||'. Room total: '||trim(p.currency)||' '||s.quote||'. Your booking is saved with the hotel. Upload identity documents securely: '||private.journey_private_link(c.id,rid,'documents',p_origin)||'. Reply Hi to choose stay updates and continue to check-in. No payment has been collected.';
  perform private.queue_journey_reply(c.id,p_source,'enquiry_confirmed',body,null);return 1;
 end if;
 if s.step in('arrival','departure')then
  begin if coalesce(raw,'')!~'^\s*[0-9]{4}-[0-9]{2}-[0-9]{2}\s*$'then raise exception 'invalid';end if;day:=trim(raw)::date;
  exception when others then perform private.enquiry_reply(c.id,p_source,'Please send a valid date as YYYY-MM-DD, for example '||((now()at time zone p.timezone)::date+1)||'.');return 1;end;
  if day<(now()at time zone p.timezone)::date or day>(now()at time zone p.timezone)::date+730 or(s.step='departure'and(day<=s.check_in or day-s.check_in>30))then perform private.enquiry_reply(c.id,p_source,'Choose upcoming dates within two years and a stay of 1–30 nights. For longer stays, send RECEPTION.');return 1;end if;
  if s.step='arrival'then update private.whatsapp_booking_sessions set check_in=day,step='departure',version=version+1 where conversation_id=c.id;body:='What is your departure date? Send YYYY-MM-DD, after '||day||'.';
  else update private.whatsapp_booking_sessions set check_out=day,step='guests',version=version+1 where conversation_id=c.id;body:='How many adults and children will stay in this one room? Send adults,children, for example 2,0 (two adults, no children). For several rooms, send RECEPTION.';end if;
 elsif s.step='guests'then
  party:=regexp_match(lower(trim(raw)),'^([1-9][0-9]?)\s*(?:adults?)?\s*[,/]\s*([0-9]{1,2})\s*(?:children|child)?$');
  if party is null or party[1]::integer+party[2]::integer>30 then perform private.enquiry_reply(c.id,p_source,'Please send adults,children as two numbers, for example 2,0. For large groups, send RECEPTION.');return 1;end if;
  update private.whatsapp_booking_sessions set adults=party[1]::integer,children=party[2]::integer,step='name',version=version+1 where conversation_id=c.id;body:='What is the full name of the booking guest? Send the name as it appears on their identity document.';
 elsif s.step='name'then
  if length(trim(coalesce(raw,'')))not between 2 and 120 or raw~'[[:cntrl:]]'then perform private.enquiry_reply(c.id,p_source,'Please send the guest’s full name using 2–120 characters.');return 1;end if;
  update private.whatsapp_booking_sessions set guest_name=trim(raw),step='rooms',version=version+1 where conversation_id=c.id;perform private.enquiry_rooms(c.id,p_source);return 1;
 elsif s.step='rooms'then perform private.enquiry_rooms(c.id,p_source);return 1;
 else body:='Use Confirm booking above to accept the quote, or send BOOK to start again. No reservation is created by a text reply.';end if;
 perform private.enquiry_reply(c.id,p_source,body);return 1;
end $$;

-- Numeric guest counts and dates belong to a booking session, not menu shortcuts.
do $$declare d text;needle text:='if job.command like ''guest:v:%''or job.command~''^(10|[1-9])$''then continue;end if;';begin
 d:=pg_get_functiondef('public.dispatch_whatsapp_guest_replies(integer,text)'::regprocedure);
 if strpos(d,needle)=0 then raise exception 'Unexpected dispatcher definition.';end if;
 d:=replace(d,needle,'if (job.command like ''guest:v:%''or job.command~''^(10|[1-9])$'')and not exists(select 1 from private.whatsapp_booking_sessions where conversation_id=job.conversation_id and step not in(''booked'',''cancelled'')and expires_at>now())and(job.command like ''guest:v:%''or not private.whatsapp_enquiry(job.conversation_id))then continue;end if;');
 d:=replace(d,'and exists(select 1 from public.messages where conversation_id=job.conversation_id and journey_purpose in(''menu'',''preferences'')','and not exists(select 1 from private.whatsapp_booking_sessions where conversation_id=job.conversation_id and step not in(''booked'',''cancelled'')and expires_at>now())and exists(select 1 from public.messages where conversation_id=job.conversation_id and journey_purpose in(''menu'',''preferences'')');execute d;
end $$;

alter function private.inbox_delivery_error(uuid)rename to inbox_delivery_error_before_enquiries;
create function private.inbox_delivery_error(p_message uuid)returns text language plpgsql stable security definer set search_path=''as $$declare why text;m public.messages;begin
 why:=private.inbox_delivery_error_before_enquiries(p_message);if why is not null then return why;end if;
 select *into m from public.messages where id=p_message;
 if m.journey_purpose='enquiry_booking'then
  if not private.whatsapp_booking_enabled(m.property_id)then return 'WhatsApp bookings are disabled.';end if;
  if m.enquiry_session is not null and not exists(select 1 from private.whatsapp_booking_sessions s join public.conversations c on c.id=s.conversation_id where s.conversation_id=m.conversation_id and s.id=m.enquiry_session and s.version=m.enquiry_revision and s.expires_at>now()and s.phone=c.wa_contact_id and s.connection_id=c.connection_id)then return 'Booking enquiry changed or expired.';end if;
 end if;return null;
end $$;

-- Apply the audience filter inside the paginated base query, never after LIMIT.
do $$declare d text;needle text:='where c.property_id=p_property and (q=';begin
 d:=pg_get_functiondef('public.inbox_workspace_before_concierge(uuid,jsonb)'::regprocedure);
 if strpos(d,needle)=0 then raise exception 'Unexpected inbox definition.';end if;
 d:=replace(d,needle,'where c.property_id=p_property and(case coalesce(p_filters->>''audience'',''all'')when ''enquiries''then private.whatsapp_enquiry(c.id)when ''guests''then not private.whatsapp_enquiry(c.id)else true end)and (q=');execute d;
end $$;
alter function public.inbox_workspace(uuid,jsonb)rename to inbox_workspace_before_enquiries;
revoke all on function public.inbox_workspace_before_enquiries(uuid,jsonb)from public,anon,authenticated,service_role;
create function public.inbox_workspace(p_property uuid,p_filters jsonb default '{}')returns jsonb language plpgsql stable security definer set search_path=''as $$declare d jsonb;begin
 d:=public.inbox_workspace_before_enquiries(p_property,p_filters);
 return d||jsonb_build_object('audiences',(select jsonb_build_object('all',count(*),'enquiries',count(*)filter(where private.whatsapp_enquiry(id)),'guests',count(*)filter(where not private.whatsapp_enquiry(id)))from public.conversations where property_id=p_property and status='open'),'stats',(select jsonb_build_object('open',count(*),'mine',count(*)filter(where c.assigned_to=auth.uid()),'unassigned',count(*)filter(where c.assigned_to is null))from public.conversations c where c.property_id=p_property and c.status='open'and(case coalesce(p_filters->>'audience','all')when 'enquiries'then private.whatsapp_enquiry(c.id)when 'guests'then not private.whatsapp_enquiry(c.id)else true end)),'current',case when d->>'current'is null then null else d->'current'||jsonb_build_object('audience',case when private.whatsapp_enquiry((d#>>'{current,id}')::uuid)then'enquiries'else'guests'end)end);
end $$;
revoke all on function public.inbox_workspace(uuid,jsonb)from public,anon;
grant execute on function public.inbox_workspace(uuid,jsonb)to authenticated;
do $$declare d text;begin
 d:=pg_get_functiondef('public.reservation_workspace(uuid,jsonb)'::regprocedure);
 if strpos(d,'r.status,r.source,r.check_in')=0 then raise exception 'Unexpected reservation projection.';end if;
 execute replace(d,'r.status,r.source,r.check_in','r.status,r.source,r.booking_origin,r.check_in');
end $$;
revoke all on function private.whatsapp_booking_enabled(uuid),private.whatsapp_enquiry(uuid),private.enquiry_button(uuid,text,text,jsonb),private.enquiry_reply(uuid,uuid,text,jsonb,boolean),private.enquiry_rooms(uuid,uuid,integer),private.confirm_enquiry_booking(uuid,uuid),private.handle_whatsapp_journey(uuid,uuid,text,text),private.inbox_delivery_error(uuid)from public,anon,authenticated,service_role;
