-- A WhatsApp booking is provisional until 50% has been captured by the hotel's merchant.
alter table public.hotel_payment_connections drop constraint hotel_payment_connections_mode_check;
alter table public.hotel_payment_connections add constraint hotel_payment_connections_mode_check check(mode in('test','live'));
alter table public.hotel_payment_requests add column purpose text not null default 'checkout'check(purpose in('checkout','booking_deposit'));
alter table public.reservations drop constraint reservations_status_check;
alter table public.reservations add constraint reservations_status_check check(status in('pending_payment','confirmed','checked_in','checked_out','cancelled','no_show'));
alter table private.whatsapp_booking_sessions drop constraint whatsapp_booking_sessions_step_check;
alter table private.whatsapp_booking_sessions add constraint whatsapp_booking_sessions_step_check check(step in('arrival','departure','guests','name','rooms','confirm','awaiting_payment','booked','cancelled'));
alter table private.whatsapp_booking_sessions add column deposit_expires_at timestamptz,add column payment_request_id uuid references public.hotel_payment_requests(id);
alter table public.reservations add column deposit_expires_at timestamptz;

-- Existing service-only commit verifies mode from the validated key hint.
do $$declare d text;begin
 d:=pg_get_functiondef('public.payment_connection_commit(uuid,uuid,uuid,text,text,boolean)'::regprocedure);
 d:=replace(d,'if p_test_hotel is not true then','if p_key_hint like ''rzp_test_%''and p_test_hotel is not true then');
 d:=replace(d,'^rzp_test_.*[a-zA-Z0-9]{4}$','^rzp_(test|live)_.*[a-zA-Z0-9]{4}$');
 d:=replace(d,'set payment_test_mode=true','set payment_test_mode=p_key_hint like ''rzp_test_%''');
 d:=replace(d,'p_property,''test'',p_key_hint','p_property,case when p_key_hint like ''rzp_live_%''then''live''else''test''end,p_key_hint');execute d;
end $$;

create function private.expire_whatsapp_deposits()returns integer language plpgsql security definer set search_path=''as $$
declare r public.reservations;job public.hotel_payment_requests;n integer:=0;begin
 for r in select *from public.reservations where status='pending_payment'and deposit_expires_at<=now()order by deposit_expires_at limit 100 for update skip locked loop
  select *into job from public.hotel_payment_requests where reservation_id=r.id and purpose='booking_deposit'for update;
  if job.state='paid'then continue;end if;
  update public.reservations set status='cancelled',notes=left(coalesce(notes,'')||E'\nDeposit hold expired before verified payment.',2000)where id=r.id;
  update public.unit_holds set active=false where reservation_id=r.id and active;
  update public.hotel_payment_requests set state=case when not creation_started and lease is null then'expired'else'cancel_pending'end,reconcile_needed=creation_started,next_check_at=now()where id=job.id;
  update private.whatsapp_booking_sessions set step='cancelled',version=version+1 where reservation_id=r.id;
  perform private.capture_whatsapp_event(r.property_id,r.id,'booking_payment_expired','deposit-expired:'||r.id,'hotel_payment_requests',job.id,null,jsonb_build_object('amount',job.amount::numeric/100));
  n:=n+1;
 end loop;return n;
end $$;
revoke all on function private.expire_whatsapp_deposits()from public,anon,authenticated,service_role;

create function private.finish_whatsapp_deposit(p_request uuid)returns void language plpgsql security definer set search_path=''as $$
declare job public.hotel_payment_requests;r public.reservations;begin
 select reservation_id into r.id from public.hotel_payment_requests where id=p_request;
 select *into r from public.reservations where id=r.id for update;
 select *into job from public.hotel_payment_requests where id=p_request and purpose='booking_deposit'and state='paid'for update;
 if job.id is null then return;end if;
 if r.status='confirmed'then return;end if;
 if r.status='pending_payment'and r.deposit_expires_at>now()and exists(select 1 from public.unit_holds where reservation_id=r.id and active)and not exists(select 1 from public.refunds rf join public.payments pay on pay.id=rf.payment_id where pay.online_request_id=job.id)then
  update public.reservations set status='confirmed',deposit_expires_at=null where id=r.id;
  update private.whatsapp_booking_sessions set step='booked',version=version+1 where reservation_id=r.id;
  perform private.capture_whatsapp_event(r.property_id,r.id,'booking_deposit_paid','deposit-paid:'||job.id,'hotel_payment_requests',job.id,'paid',jsonb_build_object('amount',job.amount::numeric/100));
 else
  update public.hotel_payment_requests set last_error='Payment received after the booking hold ended, or it was refunded. Staff must arrange a refund or a new booking; the room was not confirmed.',reconcile_needed=false where id=job.id;
  insert into public.reservation_events(tenant_id,property_id,reservation_id,event_type,details)select r.tenant_id,r.property_id,r.id,'deposit_needs_review',jsonb_build_object('payment_request',job.id)where not exists(select 1 from public.reservation_events where reservation_id=r.id and event_type='deposit_needs_review'and details->>'payment_request'=job.id::text);
 end if;
end $$;
revoke all on function private.finish_whatsapp_deposit(uuid)from public,anon,authenticated,service_role;

-- Payment notices are bound to the quoted reservation and validated sender.
alter function private.payment_guest_notice(uuid,boolean)rename to payment_guest_notice_checkout;
revoke all on function private.payment_guest_notice_checkout(uuid,boolean)from public,anon,authenticated,service_role;
create function private.payment_guest_notice(p_request uuid,p_paid boolean)returns uuid language plpgsql security definer set search_path=''as $$
declare job public.hotel_payment_requests;c public.conversations;r public.reservations;body text;payload jsonb;mid uuid;mode text;begin
 select *into job from public.hotel_payment_requests where id=p_request;
 if job.purpose<>'booking_deposit'then return private.payment_guest_notice_checkout(p_request,p_paid);end if;
 select *into c from public.conversations where id=job.conversation_id;
 select *into r from public.reservations where id=job.reservation_id;
 if c.guest_id is distinct from r.guest_id or c.wa_contact_id is distinct from(select private.campaign_phone(phone)from public.guests where id=r.guest_id)or not exists(select 1 from private.whatsapp_booking_contacts where reservation_id=r.id and conversation_id=c.id and phone=c.wa_contact_id)then return null;end if;
 if p_paid then
  -- The booking welcome is the single confirmation/document message. A separate
  -- deposit event records the receipt; don't send another duplicate welcome here.
  if r.status='confirmed'then return null;end if;
  body:='Your payment was received after the booking hold ended. The room is not confirmed. Reception will arrange a refund or help you make a new booking. Please do not pay again.';
 else
  if job.state<>'ready'or r.status<>'pending_payment'or r.deposit_expires_at<=now()or job.link_message_id is not null then return null;end if;
  select hotel_payment_connections.mode into mode from public.hotel_payment_connections where id=job.connection_id;
  body:='Pay the 50% booking deposit of '||(job.amount::numeric/100)||' INR to confirm booking '||upper(left(replace(r.id::text,'-',''),8))||'. The remaining room balance is '||(r.total_amount-job.amount::numeric/100)||' INR, plus any extras. This room is held until '||to_char(r.deposit_expires_at at time zone(select timezone from public.properties where id=r.property_id),'DD-MM-YYYY HH24:MI')||'. Booking confirms only after verified payment.'||case when mode='test'then' TEST MODE: no real money is collected.'else''end;
  payload:=jsonb_build_object('type','interactive','interactive',jsonb_build_object('type','cta_url','body',jsonb_build_object('text',body),'action',jsonb_build_object('name','cta_url','parameters',jsonb_build_object('display_text','Pay 50% deposit','url',job.short_url))));
 end if;
 mid:=private.queue_journey_reply(c.id,job.source_message_id,case when p_paid then'deposit_exception:'else'deposit_link:'end||job.id,body,payload,null);
 if mid is not null then update public.messages set payment_request_id=job.id where id=mid;end if;return mid;
end $$;
revoke all on function private.payment_guest_notice(uuid,boolean)from public,anon,authenticated,service_role;

do $$declare d text;begin
 d:=pg_get_functiondef('public.claim_online_payment()'::regprocedure);d:=replace(d,'begin',E'begin\n perform private.expire_whatsapp_deposits();');execute d;
 d:=pg_get_functiondef('public.apply_online_payment(uuid,uuid,jsonb)'::regprocedure);
 d:=replace(d,'case when private.reservation_balance(job.reservation_id)*100<>job.amount then','case when job.purpose=''checkout''and private.reservation_balance(job.reservation_id)*100<>job.amount then');
 d:=replace(d,'if status=''paid''then mid:=',E'if status=''paid''and job.purpose=''booking_deposit''then perform private.finish_whatsapp_deposit(job.id);end if;\n if status=''paid''then mid:=');execute d;
 -- Expired holds never emit the normal booking-cancelled notice.
 d:=pg_get_functiondef('private.whatsapp_domain_event()'::regprocedure);d:=replace(d,'if ev is not null and rid is not null then',E'if tg_table_name=''reservations''and prev->>''status''=''pending_payment''and st=''cancelled''then ev:=null;end if;\n if ev is not null and rid is not null then');execute d;
end $$;

CREATE OR REPLACE FUNCTION private.confirm_enquiry_booking(p_conversation uuid, p_source uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s private.whatsapp_booking_sessions;c public.conversations;p public.properties;gid uuid;rid uuid;unit uuid;price numeric;pay_connection public.hotel_payment_connections;intent uuid;expiry timestamptz;folio uuid;begin
 select *into c from public.conversations where id=p_conversation for update;
 select *into s from private.whatsapp_booking_sessions where conversation_id=c.id for update;
 select *into p from public.properties where id=c.property_id for update;
 if s.reservation_id is not null then return s.reservation_id;end if;
 if s.step<>'confirm'or s.expires_at<=now()or s.quote_expires_at<=now()or s.connection_id<>c.connection_id or s.phone<>c.wa_contact_id or not private.whatsapp_booking_enabled(p.id)then raise exception 'Your booking quote expired. Choose a room again.'using errcode='22023';end if;
 select *into pay_connection from public.hotel_payment_connections where property_id=p.id and status='active'and checkout_enabled;
 if pay_connection.id is null or p.currency<>'INR' or not exists(select 1 from private.payment_worker_configuration where id=true and enabled)then raise exception 'Online deposit payments are not ready for this hotel. Reception can help with a booking.'using errcode='22023';end if;
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
 insert into public.reservations(tenant_id,property_id,guest_id,source,booking_origin,check_in,check_out,adults,children,rate_plan_id,total_amount,currency,creation_request_id,notes,status,deposit_expires_at)
 values(p.tenant_id,p.id,gid,'direct','whatsapp',s.check_in,s.check_out,s.adults,s.children,s.rate_id,price,p.currency,s.id,'Guest requested this booking in WhatsApp; 50% deposit is required.','pending_payment',now()+interval '15 minutes')returning id into rid;
 unit:=private.frontdesk_allocate(p.id,p.tenant_id,s.type_id,s.check_in,s.check_out,rid,null);
 update public.conversations set guest_id=gid,contact_name=s.guest_name where id=c.id;
 insert into private.whatsapp_booking_contacts(reservation_id,property_id,guest_id,conversation_id,phone,evidence,actor_id)values(rid,p.id,gid,c.id,c.wa_contact_id,'Guest explicitly confirmed the quoted booking and requested its confirmation and document link in WhatsApp. Source message: '||p_source,null);
 insert into public.reservation_events(tenant_id,property_id,reservation_id,event_type,details)values(p.tenant_id,p.id,rid,'created',jsonb_build_object('source','whatsapp','unit_id',unit,'source_message',p_source,'session',s.id));
 folio:=private.ensure_folio(rid);
 insert into public.hotel_payment_requests(tenant_id,property_id,reservation_id,folio_id,connection_id,request_id,amount,currency,conversation_id,source_message_id,purpose,expires_at)values(p.tenant_id,p.id,rid,folio,pay_connection.id,s.id,ceil(price*50)::bigint,'INR',c.id,p_source,'booking_deposit',now()+interval '15 minutes')returning id into intent;
 update private.whatsapp_booking_sessions set step='awaiting_payment',reservation_id=rid,payment_request_id=intent,deposit_expires_at=now()+interval '15 minutes',expires_at=now()+interval '15 minutes',version=version+1 where conversation_id=c.id;
 perform private.capture_whatsapp_event(p.id,rid,'booking_deposit_requested','deposit-requested:'||intent,'hotel_payment_requests',intent,null,jsonb_build_object('amount',ceil(price*50)/100));
 perform private.invoke_payment_cloud_worker();
 update public.whatsapp_automation_events set next_check_at=now()where reservation_id=rid and event_key='booking_confirmed'and state in('pending','blocked');
 perform private.wake_whatsapp_guest_worker();return rid;
end $function$;

CREATE OR REPLACE FUNCTION private.handle_whatsapp_journey_before_photos(p_conversation uuid, p_source uuid, p_command text, p_origin text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  perform private.enquiry_reply(c.id,p_source,'Let’s book one room at '||left(p.name,180)||'. What is your check-in date? Send DD-MM-YYYY, for example '||((now()at time zone p.timezone)::date+1)||'. Send CANCEL BOOKING ENQUIRY to stop. For groups, send RECEPTION.');return 1;
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
  update private.whatsapp_booking_sessions set step='confirm',type_id=(a.details->>'type')::uuid,quote=price,quote_expires_at=now()+interval '10 minutes',version=version+1 where conversation_id=c.id;
  body:='Review your booking at '||left(p.name,180)||E'\nGuest: '||s.guest_name||E'\nRoom: '||left(type_name,120)||E'\nArrival: '||s.check_in||E'\nDeparture: '||s.check_out||E'\nGuests: '||s.adults||' adult(s), '||s.children||E' child(ren)\nRoom total before extras: '||trim(p.currency)||' '||price||E'\nA 50% deposit is required to confirm this booking. The room is held for 15 minutes while you pay securely; the remaining room charge and extras are due later. By continuing you request the payment link, booking confirmation and secure document-upload link. Ongoing updates and offers are separate choices. Quote valid for 10 minutes; availability is rechecked.';
  perform private.enquiry_reply(c.id,p_source,body,private.journey_buttons_payload(body,jsonb_build_array(private.enquiry_button(c.id,'enquiry_confirm','Pay 50% to confirm'),private.enquiry_button(c.id,'enquiry_start','Change details'),private.enquiry_button(c.id,'enquiry_cancel','Cancel enquiry'))));return 1;
 end if;
 if a.action='enquiry_confirm'and s.step='confirm'then
  begin rid:=private.confirm_enquiry_booking(c.id,p_source);
  exception when sqlstate 'P0002'or sqlstate '23P01'or sqlstate '22023'then
   body:=left(sqlerrm,300)||' No booking was created. Choose Change details for a fresh quote, or ask reception.';
   update private.whatsapp_booking_sessions set step='rooms',version=version+1 where conversation_id=c.id;
   perform private.enquiry_reply(c.id,p_source,body,private.journey_buttons_payload(body,jsonb_build_array(private.enquiry_button(c.id,'enquiry_start','Change details'),private.enquiry_button(c.id,'enquiry_reception','Talk to reception'))));return 1;
  end;
  body:='Your room is held for 15 minutes while we prepare your secure 50% deposit link. The booking is awaiting payment and is not confirmed yet.';
  perform private.queue_journey_reply(c.id,p_source,'deposit_preparing',body,null,null);return 1;
 end if;
 if s.step in('arrival','departure')then
  begin if trim(coalesce(raw,''))~'^[0-9]{2}-[0-9]{2}-[0-9]{4}$'then day:=to_date(trim(raw),'DD-MM-YYYY');if to_char(day,'DD-MM-YYYY')<>trim(raw)then raise exception 'invalid';end if;elsif trim(coalesce(raw,''))~'^[0-9]{4}-[0-9]{2}-[0-9]{2}$'then day:=trim(raw)::date;else raise exception 'invalid';end if;
  exception when others then perform private.enquiry_reply(c.id,p_source,'Please send a valid date as DD-MM-YYYY, for example '||((now()at time zone p.timezone)::date+1)||'.');return 1;end;
  if day<(now()at time zone p.timezone)::date or day>(now()at time zone p.timezone)::date+730 or(s.step='departure'and(day<=s.check_in or day-s.check_in>30))then perform private.enquiry_reply(c.id,p_source,'Choose upcoming dates within two years and a stay of 1–30 nights. For longer stays, send RECEPTION.');return 1;end if;
  if s.step='arrival'then update private.whatsapp_booking_sessions set check_in=day,step='departure',version=version+1 where conversation_id=c.id;body:='What is your check-out date? Send DD-MM-YYYY, after '||day||'.';
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
end $function$;
-- Expiration runs in the database even if the provider worker is temporarily offline.
select cron.schedule('hospitality-deposit-expiry','* * * * *','select private.expire_whatsapp_deposits()');

alter function private.handle_whatsapp_journey(uuid,uuid,text,text)rename to handle_whatsapp_journey_before_deposits;
revoke all on function private.handle_whatsapp_journey_before_deposits(uuid,uuid,text,text)from public,anon,authenticated,service_role;
create function private.handle_whatsapp_journey(p_conversation uuid,p_source uuid,p_command text,p_origin text)returns integer language plpgsql security definer set search_path=''as $$
declare s private.whatsapp_booking_sessions;c public.conversations;job public.hotel_payment_requests;mid uuid;begin
 select *into s from private.whatsapp_booking_sessions where conversation_id=p_conversation and step='awaiting_payment';
 if s.id is null or p_command in('photos','photo','hotel photos','resort photos','pictures','reception','human','agent')then return private.handle_whatsapp_journey_before_deposits(p_conversation,p_source,p_command,p_origin);end if;
 select *into c from public.conversations where id=p_conversation for update;
 if c.id is null or c.human_handoff or c.status<>'open'or c.last_inbound_at<=now()-interval '24 hours'or private.is_opted_out(c.property_id,c.wa_contact_id)or not private.tenant_is_active(c.tenant_id)or not exists(select 1 from public.whatsapp_journey_settings where property_id=c.property_id and enabled)or exists(select 1 from public.whatsapp_default_setup where property_id=c.property_id and configured_by is not null and not enabled)or not exists(select 1 from public.messages where id=p_source and conversation_id=c.id and direction='in')then return 0;end if;
 perform private.expire_whatsapp_deposits();
 select *into job from public.hotel_payment_requests where id=s.payment_request_id;
 if job.state='paid'then return private.handle_whatsapp_journey_before_deposits(p_conversation,p_source,'hi',p_origin);end if;
 if s.deposit_expires_at<=now()then perform private.queue_journey_reply(c.id,p_source,'deposit_expired','Your booking hold expired before payment was verified. No room is confirmed. Send BOOK to check current availability again. If you already paid, contact reception before paying again.',null);return 1;end if;
 if p_command='cancel booking enquiry'then
  update public.reservations set deposit_expires_at=now()where id=s.reservation_id and status='pending_payment';perform private.expire_whatsapp_deposits();
  perform private.queue_journey_reply(c.id,p_source,'deposit_cancelled','Your provisional booking has been cancelled and its room released. Do not use the old payment link. Send BOOK to start again.',null);return 1;
 end if;
 update public.hotel_payment_requests set source_message_id=p_source,link_message_id=null,reconcile_needed=true,next_check_at=now()where id=job.id;
 if job.state='ready'then mid:=private.payment_guest_notice(job.id,false);update public.hotel_payment_requests set link_message_id=mid where id=job.id;
 else perform private.queue_journey_reply(c.id,p_source,'deposit_pending','Your booking is still awaiting its 50% deposit. We are checking the payment link. No room is confirmed until payment is verified. Send RECEPTION if you need help.',null);end if;
 perform private.invoke_payment_cloud_worker();return 1;
end $$;
revoke all on function private.handle_whatsapp_journey(uuid,uuid,text,text)from public,anon,authenticated,service_role;

alter function private.inbox_delivery_error(uuid)rename to inbox_delivery_error_before_deposits;
revoke all on function private.inbox_delivery_error_before_deposits(uuid)from public,anon,authenticated,service_role;
create function private.inbox_delivery_error(p_message uuid)returns text language plpgsql stable security definer set search_path=''as $$
declare m public.messages;job public.hotel_payment_requests;c public.conversations;r public.reservations;why text;begin
 select *into m from public.messages where id=p_message;
 if m.automation_native then why:=private.whatsapp_native_event_error(m.automation_event_id);if why is not null then return why;end if;end if;
 if m.payment_request_id is not null then
  select *into job from public.hotel_payment_requests where id=m.payment_request_id;
  if job.purpose='booking_deposit'then
   select *into c from public.conversations where id=m.conversation_id;select *into r from public.reservations where id=job.reservation_id;
   if c.id is distinct from job.conversation_id or c.guest_id is distinct from r.guest_id or c.wa_contact_id is distinct from(select private.campaign_phone(phone)from public.guests where id=r.guest_id)or not exists(select 1 from private.whatsapp_booking_contacts where reservation_id=r.id and conversation_id=c.id and phone=c.wa_contact_id)then return 'Booking payment contact changed.';end if;
   if m.journey_purpose like'deposit_link:%'and(job.state<>'ready'or r.status<>'pending_payment'or job.expires_at<=now()or r.deposit_expires_at<=now()or not exists(select 1 from public.hotel_payment_connections where id=job.connection_id and status='active'and checkout_enabled))then return 'Booking deposit link expired or closed.';end if;
  end if;
 end if;
 return private.inbox_delivery_error_before_deposits(p_message);
end $$;
revoke all on function private.inbox_delivery_error(uuid)from public,anon,authenticated,service_role;
