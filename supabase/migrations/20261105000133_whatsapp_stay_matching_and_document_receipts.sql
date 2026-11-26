-- Match the current stay before upcoming bookings. Checkout dates are exclusive for
-- confirmed stays; checked-in guests remain reachable until staff complete checkout.
create function private.journey_candidate_stays(p_conversation uuid)returns setof uuid
language sql stable security definer set search_path=''as $$
 with eligible as(
  select r.id,r.check_in,case when r.status='checked_in'then 0 when r.check_in<=(now()at time zone p.timezone)::date then 1 else 2 end as tier
  from public.conversations c join public.guests g on g.id=c.guest_id and private.campaign_phone(g.phone)=c.wa_contact_id
  join public.reservations r on r.guest_id=g.id and r.property_id=c.property_id join public.properties p on p.id=r.property_id
  where c.id=p_conversation and(r.status='checked_in'or r.status='confirmed'and r.check_out>(now()at time zone p.timezone)::date)
  and(exists(select 1 from public.whatsapp_guest_authorizations a where a.conversation_id=c.id and a.guest_id=g.id and a.status='granted'and a.wa_contact_id=c.wa_contact_id)
   or exists(select 1 from private.whatsapp_booking_contacts b where b.reservation_id=r.id and b.conversation_id=c.id and b.guest_id=g.id and b.phone=c.wa_contact_id))
 ),ranked as(select *,min(tier)over()as best_tier,min(check_in)over(partition by tier)as first_arrival from eligible)
 select id from ranked where tier=best_tier and(tier<>2 or check_in=first_arrival)
$$;
create or replace function private.journey_stay(p_conversation uuid)returns uuid
language sql stable security definer set search_path=''as $$
 with candidates as materialized(select private.journey_candidate_stays(p_conversation)as id),chosen as(
  select a.reservation_id from private.whatsapp_journey_actions a join public.conversations c on c.id=a.conversation_id
  join public.reservations r on r.id=a.reservation_id join public.whatsapp_journey_settings s on s.property_id=c.property_id
  where a.conversation_id=p_conversation and a.action='choose_stay'and a.consumed_at is not null and a.expires_at>now()
  and a.phone=c.wa_contact_id and a.connection_id=c.connection_id and a.settings_version=s.version and a.reservation_version=r.version
  and a.reservation_id in(select id from candidates)order by a.consumed_at desc,a.id desc limit 1)
 select coalesce((select reservation_id from chosen),(select case when count(*)=1 then(array_agg(id))[1]end from candidates))
$$;
revoke all on function private.journey_candidate_stays(uuid),private.journey_stay(uuid)from public,anon,authenticated,service_role;

-- An unarrived reservation ending today must not hide a completed guest's post-stay menu either.
create or replace function private.poststay_reservation(p_conversation uuid)returns uuid language sql stable security definer set search_path=''as $$
 select r.id from public.conversations c join public.guests g on g.id=c.guest_id and private.campaign_phone(g.phone)=c.wa_contact_id join public.reservations r on r.guest_id=g.id and r.property_id=c.property_id
 where c.id=p_conversation and r.status='checked_out'and(exists(select 1 from public.whatsapp_guest_authorizations a where a.conversation_id=c.id and a.guest_id=g.id and a.wa_contact_id=c.wa_contact_id and a.status='granted')or exists(select 1 from private.whatsapp_booking_contacts b where b.reservation_id=r.id and b.guest_id=g.id and b.conversation_id=c.id and b.phone=c.wa_contact_id))
 and not exists(select 1 from public.reservations active where active.property_id=c.property_id and active.guest_id=g.id and(active.status='checked_in'or active.status='confirmed'and active.check_out>(now()at time zone(select timezone from public.properties where id=c.property_id))::date))
 order by r.checked_out_at desc nulls last,r.check_out desc,r.id limit 1
$$;
revoke all on function private.poststay_reservation(uuid)from public,anon,authenticated,service_role;

-- A missing/ambiguous identity must not silently switch the chat into human handling.
-- Verified guests with several candidate stays choose one through a scoped, expiring action.
alter function private.handle_whatsapp_journey(uuid,uuid,text,text)rename to handle_whatsapp_journey_before_stay_choice;
revoke all on function private.handle_whatsapp_journey_before_stay_choice(uuid,uuid,text,text)from public,anon,authenticated,service_role;
create function private.handle_whatsapp_journey(p_conversation uuid,p_source uuid,p_command text,p_origin text)returns integer
language plpgsql security definer set search_path=''as $$
declare c public.conversations;s public.whatsapp_journey_settings;a private.whatsapp_journey_actions;rid uuid;total integer;page integer:=0;item record;rows jsonb:='[]';body text;payload jsonb;explicit_reception boolean:=false;
begin
 select *into c from public.conversations where id=p_conversation for update;
 select *into s from public.whatsapp_journey_settings where property_id=c.property_id and enabled;
 if c.id is null or s.property_id is null or c.human_handoff or c.status<>'open'or c.last_inbound_at is null or c.last_inbound_at<now()-interval '24 hours'or private.is_opted_out(c.property_id,c.wa_contact_id)or not private.tenant_is_active(c.tenant_id)
 or exists(select 1 from public.whatsapp_default_setup where property_id=c.property_id and configured_by is not null and not enabled)
 or not exists(select 1 from public.whatsapp_connections w join public.properties p on p.id=w.property_id where w.id=c.connection_id and w.status='active'and p.archived_at is null)then return 0;end if;
 if p_command~'^journey:[a-f0-9-]{36}$'then
  select *into a from private.whatsapp_journey_actions where id=substring(p_command from 9)::uuid for update;
  if a.action in('choose_stay','choose_stay_page')then
   if a.conversation_id<>c.id or a.phone<>c.wa_contact_id or a.connection_id<>c.connection_id or a.consumed_at is not null then return 0;end if;
   if a.expires_at<=now()or a.settings_version<>s.version or(a.action='choose_stay'and not exists(select 1 from public.reservations r where r.id=a.reservation_id and r.id in(select private.journey_candidate_stays(c.id))and r.version=a.reservation_version))then
    perform private.queue_journey_reply(c.id,p_source,'stay_choice_expired','This booking choice expired or your stay changed. Send Hi for fresh options.',null);return 1;
   end if;
   update private.whatsapp_journey_actions set consumed_at=clock_timestamp(),source_message_id=p_source where id=a.id;
   if a.action='choose_stay'then p_command:='hi';else page:=greatest(0,least(1000,coalesce((a.details->>'page')::integer,0)));end if;
  end if;
 end if;
 rid:=private.journey_stay(c.id);
 if rid is not null or private.poststay_reservation(c.id)is not null then return private.handle_whatsapp_journey_before_stay_choice(c.id,p_source,p_command,p_origin);end if;
 explicit_reception:=p_command in('reception','human','agent')or(a.action='reception'and a.conversation_id=c.id and a.phone=c.wa_contact_id and a.connection_id=c.connection_id and a.consumed_at is null and a.expires_at>now()and a.settings_version=s.version);
 if explicit_reception then
  if a.id is not null then update private.whatsapp_journey_actions set consumed_at=clock_timestamp(),source_message_id=p_source where id=a.id;end if;
  perform private.queue_journey_reply(c.id,p_source,'handoff','Reception has been notified. A team member will reply here. Automatic chat replies are paused until reception resumes them.',null);
  update public.conversations set human_handoff=true,version=version+1 where id=c.id;return 1;
 end if;
 select count(*)into total from private.journey_candidate_stays(c.id);
 if total>1 then
  page:=least(page,(total-1)/7);
  for item in select r.id,r.check_in,r.check_out from public.reservations r where r.id in(select private.journey_candidate_stays(c.id))order by r.check_in,r.id offset page*7 limit 7 loop
   rows:=rows||jsonb_build_array(private.journey_button(c.id,item.id,'choose_stay','Booking '||upper(left(replace(item.id::text,'-',''),8)))||jsonb_build_object('description',item.check_in::text||' to '||item.check_out::text));
  end loop;
  if page>0 then rows:=rows||jsonb_build_array(private.journey_button(c.id,null,'choose_stay_page','Previous bookings',jsonb_build_object('page',page-1)));end if;
  if(page+1)*7<total then rows:=rows||jsonb_build_array(private.journey_button(c.id,null,'choose_stay_page','More bookings',jsonb_build_object('page',page+1)));end if;
  rows:=rows||jsonb_build_array(private.journey_button(c.id,null,'reception','Talk to reception'));
  body:='More than one booking matches your verified number. Choose the booking you need help with. No booking is changed by this choice.';
  payload:=jsonb_build_object('type','interactive','interactive',jsonb_build_object('type','list','body',jsonb_build_object('text',body),'action',jsonb_build_object('button','Choose booking','sections',jsonb_build_array(jsonb_build_object('title','Your bookings','rows',rows)))));
 else
  body:='We could not match an active booking to this verified chat. Use the WhatsApp verification option from your booking message, or choose Talk to reception for help. No private booking details are shared here.';
  payload:=private.journey_buttons_payload(body,jsonb_build_array(private.journey_button(c.id,null,'reception','Talk to reception')));
 end if;
 perform private.queue_journey_reply(c.id,p_source,'verify_stay',body,payload);return 1;
end $$;
revoke all on function private.handle_whatsapp_journey(uuid,uuid,text,text)from public,anon,authenticated,service_role;

-- Preserve the original validator and every permission/source check. A rebuilt
-- photo is still the same received document, not a stale event.
do $$declare d text;begin
 d:=pg_get_functiondef('private.whatsapp_automation_error_before_journey(uuid)'::regprocedure);
 if strpos(d,'current_status in(''clean'',''approved'')')=0 then raise exception 'Unexpected document validator definition.';end if;
 execute replace(d,'current_status in(''clean'',''approved'')','current_status in(''clean'',''image_ready'',''approved'')');
end $$;

-- Recheck every private booking choice if its queued reply reaches delivery later.
alter function private.inbox_delivery_error(uuid)rename to inbox_delivery_error_before_stay_choice;
revoke all on function private.inbox_delivery_error_before_stay_choice(uuid)from public,anon,authenticated,service_role;
create function private.inbox_delivery_error(p_message uuid)returns text language plpgsql stable security definer set search_path=''as $$
declare why text;m public.messages;choice record;
begin
 why:=private.inbox_delivery_error_before_stay_choice(p_message);if why is not null then return why;end if;
 select *into m from public.messages where id=p_message;
 if m.journey_purpose='verify_stay'then
  for choice in select a.*from jsonb_array_elements(coalesce(m.outbound_payload#>'{interactive,action,sections,0,rows}','[]'::jsonb))x
   join private.whatsapp_journey_actions a on 'journey:'||a.id::text=x->>'id'where a.action='choose_stay'loop
   if choice.conversation_id is distinct from m.conversation_id or choice.expires_at<=now()or not exists(select 1 from public.reservations r where r.id=choice.reservation_id and r.id in(select private.journey_candidate_stays(m.conversation_id))and r.version=choice.reservation_version)then return 'Guest booking choices changed. Send Hi for fresh options.';end if;
  end loop;
 end if;
 return null;
end $$;
revoke all on function private.inbox_delivery_error(uuid)from public,anon,authenticated,service_role;

-- File preparation and identity approval should wake the existing authenticated
-- delivery worker promptly, rather than waiting only for the periodic schedule.
create function private.wake_document_whatsapp()returns trigger language plpgsql security definer set search_path=''as $$begin
 if new.status is distinct from old.status and exists(select 1 from public.whatsapp_automation_events where source_table='guest_documents'and source_id=new.id and state in('pending','blocked'))then perform private.wake_whatsapp_guest_worker();end if;
 return new;
end $$;
revoke all on function private.wake_document_whatsapp()from public,anon,authenticated,service_role;
create trigger zz_wake_document_whatsapp after update of status on public.guest_documents for each row execute function private.wake_document_whatsapp();
