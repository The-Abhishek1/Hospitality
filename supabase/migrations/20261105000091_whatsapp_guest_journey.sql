-- WhatsApp-first stays. A booking contact permission is NOT ongoing/marketing consent.
create table public.whatsapp_journey_settings (
 property_id uuid primary key references public.properties(id) on delete cascade,
 enabled boolean not null default false, required_documents integer not null default 1 check(required_documents between 1 and 10),
 self_checkin boolean not null default true, version integer not null default 1,
 updated_at timestamptz not null default now(), updated_by uuid
);
alter table public.whatsapp_journey_settings enable row level security;
create policy journey_settings_read on public.whatsapp_journey_settings for select to authenticated using(private.has_permission(property_id,'staff.manage'));
revoke all on public.whatsapp_journey_settings from public,anon,authenticated;
grant select on public.whatsapp_journey_settings to authenticated;
create table private.whatsapp_booking_contacts (
 reservation_id uuid primary key references public.reservations(id) on delete cascade,
 property_id uuid not null references public.properties(id) on delete cascade,
 guest_id uuid not null references public.guests(id), conversation_id uuid not null references public.conversations(id),
 phone text not null, evidence text not null, actor_id uuid not null, created_at timestamptz not null default clock_timestamp()
);
create table private.whatsapp_journey_actions (
 id uuid primary key default gen_random_uuid(), conversation_id uuid not null references public.conversations(id) on delete cascade,
 reservation_id uuid references public.reservations(id) on delete cascade, action text not null, details jsonb not null default '{}',
 settings_version integer not null, reservation_version integer, phone text not null, connection_id uuid not null,
 created_at timestamptz not null default clock_timestamp(), expires_at timestamptz not null default(now()+interval '30 minutes'),
 consumed_at timestamptz, source_message_id uuid references public.messages(id), result_id uuid
);
revoke all on private.whatsapp_booking_contacts,private.whatsapp_journey_actions from public,anon,authenticated,service_role;
alter table public.messages add column journey_version integer,add column journey_reservation uuid references public.reservations(id),
 add column journey_purpose text,add column journey_sender text;

create function public.save_whatsapp_journey(p_property uuid,p_version integer,p_enabled boolean,p_documents integer,p_self_checkin boolean)returns void
language plpgsql security definer set search_path='' as $$
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel administrator access required.'using errcode='42501';end if;
 perform 1 from public.properties where id=p_property for update;
 perform private.staff_share(p_property);
 if coalesce((select version from public.whatsapp_journey_settings where property_id=p_property),0)<>p_version then raise exception 'Guest journey changed. Refresh before saving.'using errcode='40001';end if;
 if p_enabled is null or p_self_checkin is null or p_documents is null or p_documents not between 1 and 10 then raise exception 'Choose 1–10 required identity documents.'using errcode='22023';end if;
 if p_enabled and not exists(select 1 from public.whatsapp_connections where property_id=p_property and status='active')then raise exception 'Connect the hotel WhatsApp number first.'using errcode='22023';end if;
 insert into public.whatsapp_journey_settings(property_id,enabled,required_documents,self_checkin,updated_by)
 values(p_property,p_enabled,p_documents,p_self_checkin,auth.uid())on conflict(property_id)do update set enabled=excluded.enabled,required_documents=excluded.required_documents,self_checkin=excluded.self_checkin,version=whatsapp_journey_settings.version+1,updated_at=now(),updated_by=auth.uid();
 insert into public.whatsapp_automation_audit(property_id,tenant_id,actor,action,details)select id,tenant_id,auth.uid(),'journey_configured',jsonb_build_object('enabled',p_enabled,'required_documents',p_documents,'self_checkin',p_self_checkin)from public.properties where id=p_property;
end $$;

create function public.record_whatsapp_booking_contact(p_property uuid,p_reservation uuid,p_evidence text,p_confirmed boolean)returns void
language plpgsql security definer set search_path='' as $$
declare r public.reservations;g public.guests;w public.whatsapp_connections;cv uuid;phone text;
begin
 if not private.has_permission(p_property,'reservations.write')then raise exception 'Reservation access required.'using errcode='42501';end if;
 perform 1 from public.properties where id=p_property for update;
 perform private.staff_share(p_property);
 select *into r from public.reservations where id=p_reservation and property_id=p_property;
 if r.id is null or r.status<>'confirmed'or p_confirmed is not true or length(trim(coalesce(p_evidence,'')))not between 10 and 1000 then raise exception 'Record the guest’s verified number and prior permission for the booking welcome.'using errcode='22023';end if;
 select *into g from public.guests where id=r.guest_id;phone:=private.campaign_phone(g.phone);
 select *into w from public.whatsapp_connections where property_id=p_property and status='active';
 if phone is null or w.id is null then raise exception 'A guest number with country code and connected hotel sender are required.'using errcode='22023';end if;
 if private.is_opted_out(p_property,phone)then raise exception 'Guest has stopped messages. They must contact the hotel to resume.'using errcode='22023';end if;
 if exists(select 1 from public.whatsapp_guest_authorizations where property_id=p_property and wa_contact_id=phone and guest_id<>g.id)then raise exception 'This number belongs to another guest record. Resolve the identity before sending.'using errcode='22023';end if;
 insert into public.conversations(tenant_id,property_id,connection_id,wa_contact_id,contact_name,guest_id)values(r.tenant_id,p_property,w.id,phone,g.full_name,g.id)on conflict(connection_id,wa_contact_id)do nothing;
 select id into cv from public.conversations where connection_id=w.id and wa_contact_id=phone and(guest_id is null or guest_id=g.id);
 if cv is null then raise exception 'This number is linked to another guest. Resolve the identity first.'using errcode='22023';end if;
 update public.conversations set guest_id=g.id where id=cv;
 insert into private.whatsapp_booking_contacts(reservation_id,property_id,guest_id,conversation_id,phone,evidence,actor_id)values(r.id,p_property,g.id,cv,phone,trim(p_evidence),auth.uid())on conflict(reservation_id)do nothing;
 update public.whatsapp_automation_events set next_check_at=now()where reservation_id=r.id and event_key='booking_confirmed'and state in('pending','blocked');
 insert into public.whatsapp_automation_audit(property_id,tenant_id,actor,action,details)values(p_property,r.tenant_id,auth.uid(),'booking_contact_permission',jsonb_build_object('reservation',r.id,'evidence',trim(p_evidence),'scope','one_booking_welcome'));
 perform private.wake_whatsapp_guest_worker();
end $$;

create function public.frontdesk_create_whatsapp(p_property uuid,p_currency text,p_request uuid,p_guest_name text,p_phone text,p_email text,p_type uuid,p_in date,p_out date,p_adults integer,p_children integer,p_rate uuid default null,p_unit uuid default null,p_notes text default '',p_source text default 'direct',p_quote numeric default null,p_contact_permission boolean default false,p_contact_evidence text default '')returns uuid
language plpgsql security definer set search_path='' as $$
declare rid uuid;
begin
 if p_contact_permission then perform pg_advisory_xact_lock(hashtextextended(p_property::text||p_request::text,0));perform 1 from public.properties where id=p_property for update;end if;
 rid:=public.frontdesk_create_reviewed(p_property,p_currency,p_request,p_guest_name,p_phone,p_email,p_type,p_in,p_out,p_adults,p_children,p_rate,p_unit,p_notes,p_source,p_quote);
 if p_contact_permission then perform public.record_whatsapp_booking_contact(p_property,rid,p_contact_evidence,true);end if;
 return rid;
end $$;

-- Applies to staff, channel and chat status transitions alike. No UI-only bypass.
create function private.journey_document_error(p_reservation uuid)returns text language sql stable security definer set search_path='' as $$
 select case when count(*)filter(where d.status='approved'and d.doc_type in('id_proof','passport','visa'))<s.required_documents then 'Required identity documents must be approved by the hotel before check-in.'
 when count(*)filter(where d.status in('uploaded','clean'))>0 then 'Finish reviewing the uploaded identity documents before check-in.'end
 from public.reservations r join public.whatsapp_journey_settings s on s.property_id=r.property_id and s.enabled
 left join public.guest_documents d on d.reservation_id=r.id where r.id=p_reservation group by s.required_documents
$$;
create function private.journey_checkin_guard()returns trigger language plpgsql security definer set search_path='' as $$
declare why text;
begin
 if tg_op='INSERT'and new.status='checked_in'and exists(select 1 from public.whatsapp_journey_settings where property_id=new.property_id and enabled)then raise exception 'Create the booking as confirmed and approve its identity documents before check-in.'using errcode='22023';end if;
 if tg_op='UPDATE'and new.status='checked_in'and old.status is distinct from new.status then why:=private.journey_document_error(new.id);if why is not null then raise exception '%',why using errcode='22023';end if;end if;
 return new;
end $$;
create trigger journey_checkin_documents before insert or update of status on public.reservations for each row execute function private.journey_checkin_guard();

-- Initial welcome can use a separately recorded booking contact permission, without granting ongoing consent.
alter function private.whatsapp_automation_error(uuid)rename to whatsapp_automation_error_before_journey;
create function private.whatsapp_automation_error(p_event uuid)returns text language plpgsql stable security definer set search_path='' as $$
declare why text;e public.whatsapp_automation_events;c public.conversations;t public.message_templates;b private.whatsapp_booking_contacts;
begin
 why:=private.whatsapp_automation_error_before_journey(p_event);
 select *into e from public.whatsapp_automation_events where id=p_event;
 if e.event_key='booking_confirmed'and exists(select 1 from public.whatsapp_journey_settings where property_id=e.property_id and enabled)then
  select *into b from private.whatsapp_booking_contacts where reservation_id=e.reservation_id and guest_id=e.guest_id;
  if b.reservation_id is null then return coalesce(nullif(why,'Guest stay-update permission missing or revoked.'),'Booking welcome needs recorded prior contact permission.');end if;
  if why='Guest stay-update permission missing or revoked.'then
   select *into c from public.conversations where id=b.conversation_id;
   if b.phone is distinct from(select private.campaign_phone(phone)from public.guests where id=e.guest_id)or c.guest_id is distinct from e.guest_id or c.wa_contact_id is distinct from b.phone then return 'Guest contact binding changed.';end if;
   if private.is_opted_out(e.property_id,b.phone)or c.status<>'open'or c.human_handoff then return 'Guest opted out or conversation handed to reception.';end if;
   if not exists(select 1 from public.whatsapp_connections where id=c.connection_id and property_id=e.property_id and status='active'and(e.sender_phone_id is null or phone_number_id=e.sender_phone_id))then return 'Hotel sender is inactive or changed.';end if;
   select mt.*into t from public.message_templates mt join public.whatsapp_automation_rules wr on wr.template_id=mt.id where wr.id=e.rule_id and mt.property_id=e.property_id and mt.provider_fingerprint=wr.template_fingerprint and mt.provider_waba_id=(select waba_id from public.whatsapp_connections where id=c.connection_id);
   if t.id is null or t.status<>'approved'or not t.automation_supported or t.provider_checked_at<now()-interval '24 hours'then return 'Approved template changed, unavailable or sync is stale.';end if;
   why:=null;
  end if;
 end if;
 if why is null and e.event_key='documents_approved'and private.journey_document_error(e.reservation_id)is not null then return 'Required document review is no longer complete.';end if;
 if why is null and e.message_id is not null and exists(select 1 from public.messages m cross join lateral jsonb_array_elements(coalesce(m.template_components,'[]'))h where m.id=e.message_id and h->>'type'='header'and h#>>'{parameters,0,image,link}'is distinct from(select a.image_url from public.whatsapp_template_assets a join public.message_templates mt on mt.provider_template_id=a.provider_template_id and mt.property_id=a.property_id join public.whatsapp_automation_rules wr on wr.template_id=mt.id where wr.id=e.rule_id))then return 'Template delivery image changed.';end if;
 if why is null and exists(select 1 from public.message_templates mt join public.whatsapp_automation_rules wr on wr.template_id=mt.id where wr.id=e.rule_id and exists(select 1 from jsonb_array_elements(mt.provider_definition->'components')h where h->>'type'='HEADER'and h->>'format'='IMAGE')and not exists(select 1 from public.whatsapp_template_assets a where a.property_id=e.property_id and a.provider_template_id=mt.provider_template_id))then return 'Upload a delivery image for this template.';end if;
 return why;
end $$;

-- An authenticated inbound sender still needs an unambiguous, previously verified booking binding.
create function private.journey_stay(p_conversation uuid)returns uuid language sql stable security definer set search_path=''as $$
 select case when count(distinct r.id)=1 then (array_agg(distinct r.id))[1]end
 from public.conversations c join public.guests g on g.id=c.guest_id and private.campaign_phone(g.phone)=c.wa_contact_id
 join public.reservations r on r.guest_id=g.id and r.property_id=c.property_id join public.properties p on p.id=r.property_id
 where c.id=p_conversation and r.status in('confirmed','checked_in')and r.check_out>=(now()at time zone p.timezone)::date
 and(exists(select 1 from public.whatsapp_guest_authorizations a where a.conversation_id=c.id and a.guest_id=g.id and a.status='granted'and a.wa_contact_id=c.wa_contact_id)
 or exists(select 1 from private.whatsapp_booking_contacts b where b.reservation_id=r.id and b.conversation_id=c.id and b.guest_id=g.id and b.phone=c.wa_contact_id))
$$;

create function private.journey_button(p_conversation uuid,p_reservation uuid,p_action text,p_title text,p_details jsonb default '{}')returns jsonb
language plpgsql security definer set search_path=''as $$
declare a uuid;c public.conversations;
begin
 select *into c from public.conversations where id=p_conversation;
 insert into private.whatsapp_journey_actions(conversation_id,reservation_id,action,details,settings_version,reservation_version,phone,connection_id)
 select c.id,p_reservation,p_action,p_details,s.version,r.version,c.wa_contact_id,c.connection_id from public.whatsapp_journey_settings s left join public.reservations r on r.id=p_reservation where s.property_id=c.property_id returning id into a;
 return jsonb_build_object('id','journey:'||a,'title',left(p_title,24));
end $$;
create function private.queue_journey_reply(p_conversation uuid,p_source uuid,p_purpose text,p_body text,p_payload jsonb,p_reservation uuid default null)returns uuid
language plpgsql security definer set search_path=''as $$
declare mid uuid;c public.conversations;
begin
 select *into c from public.conversations where id=p_conversation;
 if c.status<>'open'or c.human_handoff and p_purpose<>'handoff'or c.last_inbound_at is null or c.last_inbound_at<now()-interval '24 hours'or private.is_opted_out(c.property_id,c.wa_contact_id)or not private.tenant_is_active(c.tenant_id)then return null;end if;
 insert into public.messages(tenant_id,property_id,conversation_id,direction,type,body,status,outbound_payload,guest_reply_to,guest_menu_action,journey_version,journey_reservation,journey_purpose,journey_sender)
 select c.tenant_id,c.property_id,c.id,'out',coalesce(p_payload->>'type','text'),left(p_body,4096),'queued',coalesce(p_payload,jsonb_build_object('type','text','text',jsonb_build_object('body',left(p_body,4096)))),p_source,'journey:'||p_purpose,s.version,p_reservation,p_purpose,w.phone_number_id
 from public.whatsapp_journey_settings s join public.whatsapp_connections w on w.id=c.connection_id and w.status='active'where s.property_id=c.property_id and s.enabled
 on conflict do nothing returning id into mid;
 if mid is not null then update public.conversations set last_message_at=now()where id=c.id;end if;return mid;
end $$;
create function private.journey_buttons_payload(p_body text,p_buttons jsonb)returns jsonb language sql immutable set search_path=''as $$
 select jsonb_build_object('type','interactive','interactive',jsonb_build_object('type','button','body',jsonb_build_object('text',left(p_body,1024)),'action',jsonb_build_object('buttons',(select jsonb_agg(jsonb_build_object('type','reply','reply',jsonb_build_object('id',b->>'id','title',left(b->>'title',20))))from jsonb_array_elements(p_buttons)b))))
$$;

create function private.journey_private_link(p_conversation uuid,p_reservation uuid,p_view text,p_origin text)returns text
language plpgsql security definer set search_path=''as $$
declare token text;r public.reservations;
begin
 if p_reservation is null or p_reservation is distinct from private.journey_stay(p_conversation)or p_view not in('documents','food','bill')or not private.whatsapp_public_link(p_origin)or p_origin~'[?#]'or p_origin~'/s/'then raise exception 'Private guest task unavailable. Contact reception.'using errcode='22023';end if;
 select *into r from public.reservations where id=p_reservation;
 token:=encode(extensions.gen_random_bytes(32),'hex');insert into public.guest_access_tokens(tenant_id,property_id,reservation_id,token_hash,expires_at)values(r.tenant_id,r.property_id,r.id,encode(sha256(convert_to(token,'utf8')),'hex'),now()+interval '7 days');
 return rtrim(p_origin,'/')||'/s/'||token||'?view='||p_view||'&via=whatsapp';
end $$;

create function private.journey_consent(p_conversation uuid,p_reservation uuid,p_message uuid,p_kind text)returns void
language plpgsql security definer set search_path=''as $$
declare c public.conversations;r public.reservations;
begin
 select *into c from public.conversations where id=p_conversation for update;
 if p_reservation is distinct from private.journey_stay(c.id)or p_reservation is null then raise exception 'Reception must verify this stay and number first.'using errcode='22023';end if;
 select *into r from public.reservations where id=p_reservation;
 if p_kind='updates'then
  insert into public.consent_records(property_id,tenant_id,wa_contact_id,status,source)values(c.property_id,c.tenant_id,c.wa_contact_id,'opted_in','guest_whatsapp');
  insert into public.whatsapp_guest_authorizations(property_id,tenant_id,guest_id,wa_contact_id,conversation_id,status,evidence,source,consented_at,source_message_id,consent_version)
  values(c.property_id,c.tenant_id,r.guest_id,c.wa_contact_id,c.id,'granted','Guest selected Enable stay updates in the hotel WhatsApp conversation.','guest_whatsapp',clock_timestamp(),p_message,'chat_stay_updates_v1')
  on conflict(property_id,guest_id)do update set wa_contact_id=excluded.wa_contact_id,conversation_id=excluded.conversation_id,status='granted',evidence=excluded.evidence,source=excluded.source,consented_at=excluded.consented_at,source_message_id=excluded.source_message_id,consent_version=excluded.consent_version,version=whatsapp_guest_authorizations.version+1,updated_at=clock_timestamp(),updated_by=null;
  update public.whatsapp_automation_events set next_check_at=now()where reservation_id=r.id and state='blocked'and expires_at>now();
 elsif p_kind='offers'then
  insert into public.whatsapp_marketing_permissions(property_id,tenant_id,wa_contact_id,status,evidence,actor_id,source,source_message_id,consent_version)
  values(c.property_id,c.tenant_id,c.wa_contact_id,'granted','Guest separately selected Yes, hotel offers in the WhatsApp preferences screen.',null,'guest_whatsapp',p_message,'chat_hotel_offers_v1');
 elsif p_kind='decline'then perform private.revoke_whatsapp_consent(c.property_id,c.wa_contact_id,'updates','guest_whatsapp',p_message);
 else raise exception 'Unknown messaging choice.'using errcode='22023';end if;
 insert into public.whatsapp_automation_audit(property_id,tenant_id,action,details)values(c.property_id,c.tenant_id,'chat_preference',jsonb_build_object('reservation',r.id,'choice',p_kind,'source_message',p_message));
end $$;

create function private.handle_whatsapp_journey(p_conversation uuid,p_source uuid,p_command text,p_origin text)returns integer
language plpgsql security definer set search_path=''as $$
declare c public.conversations;s public.whatsapp_journey_settings;r public.reservations;p public.properties;g public.guests;
 a private.whatsapp_journey_actions;rid uuid;action text:='menu';buttons jsonb:='[]';rows jsonb:='[]';body text;payload jsonb;url text;why text;item record;target uuid;balance numeric;page integer:=0;total integer;verified boolean;
begin
 select *into c from public.conversations where id=p_conversation for update;
 select *into s from public.whatsapp_journey_settings where property_id=c.property_id and enabled;
 if not exists(select 1 from public.whatsapp_connections w join public.properties hotel on hotel.id=w.property_id where w.id=c.connection_id and w.status='active'and hotel.archived_at is null)then return 0;end if;
 if s.property_id is null or c.human_handoff or c.status<>'open'or private.is_opted_out(c.property_id,c.wa_contact_id)or c.last_inbound_at is null or c.last_inbound_at<now()-interval '24 hours'or not private.tenant_is_active(c.tenant_id)then return 0;end if;
 rid:=private.journey_stay(c.id);
 if p_command~'^journey:[a-f0-9-]{36}$'then
  select *into a from private.whatsapp_journey_actions where id=substring(p_command from 9)::uuid for update;
  if a.id is null or a.conversation_id<>c.id or a.phone<>c.wa_contact_id or a.connection_id<>c.connection_id then return 0;end if;
  if a.consumed_at is not null then return 0;end if;
  if a.expires_at<=now()or a.settings_version<>s.version or a.reservation_id is distinct from rid then
   body:='That option has expired or your stay changed. Send Hi for a fresh menu.';
   perform private.queue_journey_reply(c.id,p_source,'expired',body,null);return 1;
  end if;
  action:=a.action;page:=coalesce((a.details->>'page')::integer,0);
  update private.whatsapp_journey_actions set consumed_at=clock_timestamp(),source_message_id=p_source where id=a.id;
 elsif p_command in('checkin','check in','check-in')then action:='checkin';
 elsif p_command in('checkout','check out','check-out')then action:='checkout';
 elsif p_command in('documents','food','services','stay','bill','preferences','reception','human','agent')then action:=case when p_command in('human','agent')then'reception'else p_command end;
 end if;
 select *into p from public.properties where id=c.property_id;
 if rid is not null then select *into r from public.reservations where id=rid for update;select *into g from public.guests where id=r.guest_id;end if;
 verified:=exists(select 1 from public.whatsapp_guest_authorizations where conversation_id=c.id and guest_id=r.guest_id and wa_contact_id=c.wa_contact_id and status='granted');
 -- Menus remain useful for unverified contacts, but never disclose somebody else's stay.
 if rid is null then
  body:='Welcome to '||p.name||'. Reception needs to verify your booking and WhatsApp number before sharing private stay details. A team member will help you here.';
  perform private.queue_journey_reply(c.id,p_source,'handoff',body,null);
  update public.conversations set human_handoff=true,version=version+1 where id=c.id;return 1;
 end if;
 if action='updates'then
  perform private.journey_consent(c.id,r.id,p_source,'updates');verified:=true;
  body:='Stay updates are enabled for '||p.name||'. Booking '||upper(left(replace(r.id::text,'-',''),8))||': '||r.check_in||' to '||r.check_out||'. Offers are optional and remain separate. Upload your identity documents securely; reception will review them before check-in. Send STOP UPDATES to stop automatic updates, or STOP to stop all messages.';
  buttons:=jsonb_build_array(private.journey_button(c.id,r.id,'documents','Upload documents'),private.journey_button(c.id,r.id,'offers_prompt','Optional offers'),private.journey_button(c.id,r.id,'menu','Guest menu'));
 elsif action='decline'then
  perform private.journey_consent(c.id,r.id,p_source,'decline');body:='Automatic stay updates are off. You can still ask reception for help here. Send Hi whenever you need the guest menu.';
 elsif action='offers_prompt'then
  body:='Would you like optional offers, promotions and review requests from '||p.name||' on WhatsApp? This choice is separate from your booking and stay updates. Send STOP OFFERS at any time.';
  buttons:=jsonb_build_array(private.journey_button(c.id,r.id,'offers','Yes, hotel offers'),private.journey_button(c.id,r.id,'no_offers','No thanks'));
 elsif action='offers'then perform private.journey_consent(c.id,r.id,p_source,'offers');body:='Optional hotel offers are enabled. Send STOP OFFERS to stop them. Your stay-update choice is unchanged. Send Hi for help.';
 elsif action='no_offers'then
  perform private.revoke_whatsapp_consent(c.property_id,c.wa_contact_id,'marketing','guest_whatsapp',p_source);body:='Optional hotel offers are off. Your stay-update choice is unchanged. Send Hi for help.';
 elsif action='preferences'or(action='menu'and not verified and not exists(select 1 from public.whatsapp_automation_audit au where au.property_id=c.property_id and au.action='chat_preference'and au.details->>'reservation'=r.id::text and au.details->>'choice'='decline'))then
  body:='Receive automatic booking, document review, check-in, food order and service updates from '||p.name||' on this WhatsApp number? Offers are separate and optional. You can withdraw at any time with STOP UPDATES or STOP.';
  buttons:=jsonb_build_array(private.journey_button(c.id,r.id,'updates','Enable stay updates'),private.journey_button(c.id,r.id,'decline','No automatic updates'),private.journey_button(c.id,r.id,'offers_prompt','Optional offers'));
 elsif action='reception'then
  body:='Reception has been notified. A team member will reply here. Automatic chat replies are paused until reception resumes them.';
  perform private.queue_journey_reply(c.id,p_source,'handoff',body,null);
  update public.conversations set human_handoff=true,version=version+1 where id=c.id;return 1;
 elsif action='stay'then
  body:=p.name||E'\nBooking: '||upper(left(replace(r.id::text,'-',''),8))||E'\nGuest: '||g.full_name||E'\nArrival: '||r.check_in||E'\nDeparture: '||r.check_out||E'\nRoom: '||coalesce(private.whatsapp_reservation_room_name(r.id),'Awaiting room assignment')||E'\nStatus: '||replace(r.status,'_',' ')||E'\nGuests: '||r.adults||' adults, '||r.children||E' children.\nSend Hi for help.';
 elsif action in('documents','food','bill')then
  if action='food'and r.status<>'checked_in'then body:='Food ordering opens after check-in. Send Hi to check your arrival status.';
  else
   url:=private.journey_private_link(c.id,r.id,action,p_origin);
   body:=case action when'documents'then'Upload identity documents securely for '||p.name||'. Do not send ID numbers or identity files into this chat. The hotel will confirm the review here. Approved documents: '||(select count(*)from public.guest_documents where reservation_id=r.id and status='approved'and doc_type in('id_proof','passport','visa'))||' / '||s.required_documents||'.'when'food'then'Choose your dishes and quantities. Your order confirmation and progress will arrive here on WhatsApp when stay updates are enabled.'else'Open your itemized bill securely. Reception handles payment and settlement; no payment is collected by this chat.'end;
   payload:=jsonb_build_object('type','interactive','interactive',jsonb_build_object('type','cta_url','body',jsonb_build_object('text',body),'action',jsonb_build_object('name','cta_url','parameters',jsonb_build_object('display_text',case action when'documents'then'Upload documents'when'food'then'Choose food'else'View bill'end,'url',url))));
  end if;
 elsif action in('checkin','confirm_checkin')then
  why:=private.journey_document_error(r.id);
  if r.status='checked_in'then body:='You are already checked in to '||p.name||', room '||coalesce(private.whatsapp_reservation_room_name(r.id),'assigned by reception')||'. Send Hi for food, services or assistance.';
  elsif not s.self_checkin then body:='Reception will complete your check-in. Send reception for assistance.';
  elsif why is not null then body:=why;buttons:=jsonb_build_array(private.journey_button(c.id,r.id,'documents','Upload documents'),private.journey_button(c.id,r.id,'reception','Talk to reception'));
  elsif(now()at time zone p.timezone)::date<r.check_in or(now()at time zone p.timezone)::date>=r.check_out then body:='Check-in is available only during your booked stay: '||r.check_in||' to '||r.check_out||'.';
  elsif now()<((r.check_in+coalesce((select check_in_time from public.property_settings where property_id=p.id),'14:00'::time))at time zone p.timezone)then body:='Your check-in opens at '||coalesce((select check_in_time::text from public.property_settings where property_id=p.id),'14:00')||' on '||r.check_in||' ('||p.timezone||'). For early arrival, contact reception.';
  elsif not exists(select 1 from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.reservation_id=r.id and h.active and u.active and u.housekeeping_status='clean')then body:='Your room is not ready for check-in yet. Reception can help with your arrival.';
  elsif action='checkin'then body:='Your documents are approved. Check in now to '||p.name||', room '||coalesce(private.whatsapp_reservation_room_name(r.id),'assigned room')||'? Your stay ends '||r.check_out||'.';buttons:=jsonb_build_array(private.journey_button(c.id,r.id,'confirm_checkin','Confirm check-in'),private.journey_button(c.id,r.id,'menu','Not now'));
  else
   if a.reservation_version is distinct from r.version then raise exception 'Your stay changed. Send Hi and choose check-in again.'using errcode='22023';end if;
   -- Serialize room occupancy with staff check-in and room moves.
   perform 1 from public.accommodation_units u join public.unit_holds h on h.unit_id=u.id where h.reservation_id=r.id and h.active for update of u;
   if exists(select 1 from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.reservation_id=r.id and h.active and(not u.active or u.housekeeping_status<>'clean'))then raise exception 'Your room is not ready. Reception will help.'using errcode='22023';end if;
   if exists(select 1 from public.unit_holds own join public.unit_holds other on other.unit_id=own.unit_id and other.active join public.reservations rr on rr.id=other.reservation_id where own.reservation_id=r.id and own.active and rr.id<>r.id and rr.status='checked_in')then raise exception 'Another guest is still in this room. Reception will help.'using errcode='22023';end if;
   update public.reservations set status='checked_in',checked_in_at=now()where id=r.id and status='confirmed';
   insert into public.reservation_events(tenant_id,property_id,reservation_id,event_type,details)values(r.tenant_id,r.property_id,r.id,'checked_in',jsonb_build_object('source','whatsapp','message_id',p_source));
   body:='Check-in confirmed at '||p.name||E'.\nGuest: '||g.full_name||E'\nRoom: '||coalesce(private.whatsapp_reservation_room_name(r.id),'assigned room')||E'\nDeparture: '||r.check_out||'. Send Hi or Hello for food, services or help.';
  end if;
 elsif action='services'then
  select count(*)into total from public.service_catalog where property_id=p.id and active;
  if total=0 then body:='Tell reception what you need and a team member will help.';buttons:=jsonb_build_array(private.journey_button(c.id,r.id,'reception','Talk to reception'));
  else
   page:=least(greatest(0,page),(total-1)/7);
   for item in select *from public.service_catalog where property_id=p.id and active order by name,id offset page*7 limit 7 loop rows:=rows||jsonb_build_array(private.journey_button(c.id,r.id,'service_prompt',left(item.name,24),jsonb_build_object('catalog_id',item.id,'catalog_version',item.version)));end loop;
   if page>0 then rows:=rows||jsonb_build_array(private.journey_button(c.id,r.id,'services','← Previous',jsonb_build_object('page',page-1)));end if;
   if(page+1)*7<total then rows:=rows||jsonb_build_array(private.journey_button(c.id,r.id,'services','More services →',jsonb_build_object('page',page+1)));end if;
   rows:=rows||jsonb_build_array(private.journey_button(c.id,r.id,'menu','← Main menu'));body:='What can we help with? Choose a service. No request is placed until you confirm.';
  end if;
 elsif action in('service_prompt','service_confirm')then
  select *into item from public.service_catalog where id=(a.details->>'catalog_id')::uuid and property_id=p.id and active;
  if not found or item.version::text is distinct from a.details->>'catalog_version'then raise exception 'This service changed. Choose it again from a fresh menu.'using errcode='22023';end if;
  if r.status<>'checked_in'then body:='Room services are available after check-in. Reception can help with pre-arrival requests.';
  elsif action='service_prompt'then body:='Request '||item.name||' for room '||coalesce(private.whatsapp_reservation_room_name(r.id),'your room')||'? '||coalesce(item.description,'')||' Reception will confirm any additional charges.';buttons:=jsonb_build_array(private.journey_button(c.id,r.id,'service_confirm','Send request',a.details),private.journey_button(c.id,r.id,'services','Cancel'));
  else
   select id into target from public.guest_requests where reservation_id=r.id and catalog_id=item.id and status in('new','in_progress')order by created_at desc limit 1;
   if target is null then target:=private.create_guest_request_core(p.id,r.id,item.id,null,'Requested and confirmed in WhatsApp.','whatsapp',null);end if;
   update private.whatsapp_journey_actions set result_id=target where id=a.id;
   body:='Your request for '||item.name||' is with the hotel team. Reference: '||upper(left(target::text,8))||'. We will send progress updates here when stay updates are enabled. Send reception if you need to add details.';
  end if;
 elsif action in('checkout','confirm_checkout')then
  if r.status<>'checked_in'then body:='You are not currently checked in. Send reception for help with your booking.';
  else
   -- Post booked nights in the transaction, then use the same settlement/cleaning core as staff.
   if action='confirm_checkout'then
    if a.reservation_version is distinct from r.version then raise exception 'Your stay changed. Review checkout again.'using errcode='22023';end if;
    perform private.post_room_nights(r.id,r.check_out-1);balance:=private.reservation_balance(r.id);
    if balance=0 and not exists(select 1 from public.orders where reservation_id=r.id and status not in('served','cancelled'))then perform private.complete_guest_checkout(r.id,p_source);body:='Checkout confirmed at '||p.name||'. Your settled balance is 0 '||trim(r.currency)||'. Thank you for staying with us.';
    else body:='Checkout needs reception assistance. Your balance is '||balance||' '||trim(r.currency)||'. Any unfinished orders must also be resolved.';buttons:=jsonb_build_array(private.journey_button(c.id,r.id,'bill','View bill'),private.journey_button(c.id,r.id,'reception','Talk to reception'));end if;
   else body:='Ready to check out from '||p.name||'? The full booked stay and extras must be settled, and food orders completed. Your current posted balance is '||private.reservation_balance(r.id)||' '||trim(r.currency)||'. Unposted room charges may still apply.';buttons:=jsonb_build_array(private.journey_button(c.id,r.id,'confirm_checkout','Confirm checkout'),private.journey_button(c.id,r.id,'bill','View bill'),private.journey_button(c.id,r.id,'menu','Not now'));end if;
  end if;
 else
  -- An owner-published menu retains its categories/templates. Built-in journey is the fallback.
  if exists(select 1 from public.whatsapp_guest_menu where property_id=p.id and enabled)then perform private.queue_whatsapp_guest_reply(c.id,null,'menu',true,p_source,p_origin);return 1;end if;
  body:='Welcome, '||g.full_name||'. How can '||p.name||' help with your stay?';
  rows:=jsonb_build_array(private.journey_button(c.id,r.id,'stay','My stay'),private.journey_button(c.id,r.id,'documents','Upload documents'),private.journey_button(c.id,r.id,'checkin','Check in'),private.journey_button(c.id,r.id,'food','Order food'),private.journey_button(c.id,r.id,'services','Request a service'),private.journey_button(c.id,r.id,'checkout','Check out'),private.journey_button(c.id,r.id,'bill','My bill'),private.journey_button(c.id,r.id,'preferences','Message preferences'),private.journey_button(c.id,r.id,'reception','Talk to reception'));
 end if;
 if jsonb_array_length(buttons)>0 then payload:=private.journey_buttons_payload(body,buttons);
 elsif jsonb_array_length(rows)>0 then payload:=jsonb_build_object('type','interactive','interactive',jsonb_build_object('type','list','body',jsonb_build_object('text',left(body,1024)),'action',jsonb_build_object('button','Choose an option','sections',jsonb_build_array(jsonb_build_object('title','Guest services','rows',rows)))));end if;
 perform private.queue_journey_reply(c.id,p_source,action,body,payload,case when action='confirm_checkout'and body like 'Checkout confirmed%'then null else r.id end);return 1;
end $$;

create or replace function private.complete_guest_checkout(p_id uuid,p_message uuid default null) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.reservations; v record; v_task uuid; v_bal numeric; v_day date;
begin
  select *into r from public.reservations where id=p_id for update;
  if r.id is null or not private.tenant_is_active(r.tenant_id)then raise exception 'Stay unavailable.'using errcode='22023';end if;
  if r.status <> 'checked_in' then raise exception 'cannot check out from status %', r.status using errcode = '22023'; end if;

  perform private.post_room_nights(p_id, r.check_out - 1);   -- the booked stay is always fully charged
  v_bal := private.reservation_balance(p_id);
  if v_bal <> 0 then raise exception 'settle the folio before checkout (balance %)', v_bal using errcode = '22023'; end if;

  update public.reservations set status = 'checked_out', checked_out_at = now() where id = p_id;
  for v in select h.unit_id, u.name from public.unit_holds h
           join public.accommodation_units u on u.id = h.unit_id
           where h.reservation_id = p_id and h.active
  loop
    update public.accommodation_units set housekeeping_status = 'dirty' where id = v.unit_id;
    v_task := null;
    insert into public.tasks (tenant_id, property_id, title, kind, unit_id, reservation_id, created_by)
    values (r.tenant_id, r.property_id, 'Clean unit ' || v.name, 'housekeeping', v.unit_id, p_id, auth.uid())
    on conflict (unit_id) where kind = 'housekeeping' and status in ('open', 'in_progress') do nothing
    returning id into v_task;
    if v_task is not null then
      insert into public.task_events (tenant_id, property_id, task_id, event_type, actor_id, details)
      values (r.tenant_id, r.property_id, v_task, 'created', auth.uid(), jsonb_build_object('source', 'checkout'));
    end if;
  end loop;
  -- Keep past occupied nights for reports; release the remaining booked nights after early departure.
  select (now() at time zone p.timezone)::date into v_day from public.properties p where p.id=r.property_id;
  update public.unit_holds set active=false
    where reservation_id=p_id and active and lower(during)>=v_day;
  update public.unit_holds set during=daterange(lower(during),v_day,'[)')
    where reservation_id=p_id and active and lower(during)<v_day and upper(during)>v_day;
  insert into public.reservation_events (tenant_id, property_id, reservation_id, event_type, actor_id)
  values (r.tenant_id, r.property_id, p_id, 'checked_out', auth.uid());
end $$;


create or replace function public.check_out_reservation(p_id uuid)returns void language plpgsql security definer set search_path=''as $$
begin perform private.lock_reservation(p_id,'frontdesk.manage');perform private.complete_guest_checkout(p_id);end $$;

-- Preserve the provider-authenticated ingest path and its STOP processing.
alter function public.ingest_whatsapp_inbound(text,text,text,text,text,text,text,jsonb,timestamptz)rename to ingest_whatsapp_inbound_before_journey;
revoke all on function public.ingest_whatsapp_inbound_before_journey(text,text,text,text,text,text,text,jsonb,timestamptz)from public,anon,authenticated,service_role;
create function public.ingest_whatsapp_inbound(p_phone_number_id text,p_event_key text,p_wa_contact_id text,p_contact_name text,p_wa_message_id text,p_type text,p_body text,p_payload jsonb,p_sent_at timestamptz default now())returns uuid
language plpgsql security definer set search_path=''as $$
declare cid uuid;mid uuid;cmd text;
begin
 cid:=public.ingest_whatsapp_inbound_before_journey(p_phone_number_id,p_event_key,p_wa_contact_id,p_contact_name,p_wa_message_id,p_type,p_body,p_payload,p_sent_at);
 cmd:=lower(trim(case p_type when'interactive'then coalesce(p_payload#>>'{interactive,list_reply,id}',p_payload#>>'{interactive,button_reply,id}','')when'button'then coalesce(p_payload#>>'{button,payload}','')else coalesce(p_body,'')end));
 cmd:=regexp_replace(cmd,'[.!?[:space:]]+$','','g');
 if cid is not null and cmd in('stop','unsubscribe','stop offers','stop marketing','stop updates','stop stay updates')then update private.whatsapp_journey_actions set expires_at=least(expires_at,clock_timestamp())where conversation_id=cid and consumed_at is null;end if;
 if cid is not null and cmd not in('stop','unsubscribe','stop offers','stop marketing','stop updates','stop stay updates')and cmd not like 'i agree to stay updates%'and exists(select 1 from public.whatsapp_journey_settings s join public.conversations c on c.property_id=s.property_id where c.id=cid and s.enabled)then
  select id into mid from public.messages where conversation_id=cid and direction='in'and wa_message_id=p_wa_message_id;
  if mid is not null then insert into private.whatsapp_guest_inbound_jobs(message_id,command)values(mid,left(cmd,200))on conflict do nothing;perform private.wake_whatsapp_guest_worker();end if;
 end if;return cid;
end $$;
grant execute on function public.ingest_whatsapp_inbound(text,text,text,text,text,text,text,jsonb,timestamptz)to service_role;
revoke all on function public.ingest_whatsapp_inbound(text,text,text,text,text,text,text,jsonb,timestamptz)from public,anon,authenticated;

alter function private.queue_whatsapp_guest_reply(uuid,uuid,text,boolean,uuid,text)rename to queue_whatsapp_guest_reply_before_journey;
create function private.queue_whatsapp_guest_reply(p_conversation uuid,p_request uuid,p_action text,p_automatic boolean,p_source uuid,p_origin text)returns uuid
language plpgsql security definer set search_path=''as $$
declare action text:=p_action;mid uuid;
begin
 if p_automatic and exists(select 1 from public.whatsapp_journey_settings s join public.conversations c on c.property_id=s.property_id where c.id=p_conversation and s.enabled)then
  if action~'^service:[a-f0-9-]{36}$'then
   select x->>'action'into action from public.whatsapp_guest_menu cfg cross join lateral jsonb_array_elements(cfg.data->'categories')k cross join lateral jsonb_array_elements(k->'services')x where cfg.property_id=(select property_id from public.conversations where id=p_conversation)and cfg.enabled and k->>'enabled'='true'and x->>'enabled'='true'and x->>'id'=split_part(p_action,':',2);
  end if;
  if action in('stay','checkin','checkout','services','food','documents')then
   perform private.handle_whatsapp_journey(p_conversation,p_source,action,p_origin);
   select id into mid from public.messages where conversation_id=p_conversation and guest_reply_to=p_source order by created_at desc,id desc limit 1;return mid;
  end if;
 end if;
 return private.queue_whatsapp_guest_reply_before_journey(p_conversation,p_request,p_action,p_automatic,p_source,p_origin);
end $$;
alter function public.dispatch_whatsapp_guest_replies(integer,text)rename to dispatch_whatsapp_guest_replies_before_journey;
revoke all on function public.dispatch_whatsapp_guest_replies_before_journey(integer,text)from public,anon,authenticated,service_role;
alter table private.whatsapp_guest_inbound_jobs add column last_error text;
create function public.dispatch_whatsapp_guest_replies(p_limit integer default 50,p_portal_origin text default null)returns integer
language plpgsql security definer set search_path=''as $$
declare job record;n integer:=0;cfg integer;action text;
begin
 for job in select j.*,m.conversation_id from private.whatsapp_guest_inbound_jobs j join public.messages m on m.id=j.message_id join public.whatsapp_journey_settings s on s.property_id=m.property_id and s.enabled where j.state='pending'order by j.created_at,j.message_id limit greatest(1,least(100,p_limit))for update of j skip locked loop
  -- Existing custom category navigation/template replies stay with the published menu dispatcher.
  if job.command like 'guest:v:%'or job.command~'^(10|[1-9])$'then continue;end if;
  update private.whatsapp_guest_inbound_jobs set state='done'where message_id=job.message_id;
  if job.command not like 'journey:%'and job.command not in('checkin','check in','check-in','checkout','check out','check-out','documents','food','services','stay','bill','preferences','reception','human','agent')and exists(select 1 from public.messages where conversation_id=job.conversation_id and journey_purpose in('menu','preferences')and created_at>now()-interval '30 seconds'and status<>'failed')then continue;end if;
  begin n:=n+private.handle_whatsapp_journey(job.conversation_id,job.message_id,job.command,p_portal_origin);
  exception when sqlstate '22023'then
   update private.whatsapp_guest_inbound_jobs set last_error=left(sqlerrm,500)where message_id=job.message_id;
   perform private.queue_journey_reply(job.conversation_id,job.message_id,'needs_attention',left(sqlerrm,500)||' Send Hi for the latest options, or reception for assistance.',null);
  end;
 end loop;
 return n+public.dispatch_whatsapp_guest_replies_before_journey(p_limit,p_portal_origin);
end $$;
revoke all on function public.dispatch_whatsapp_guest_replies(integer,text)from public,anon,authenticated;
grant execute on function public.dispatch_whatsapp_guest_replies(integer,text)to service_role;

alter function private.inbox_delivery_error(uuid)rename to inbox_delivery_error_before_journey;
create function private.inbox_delivery_error(p_message uuid)returns text language plpgsql stable security definer set search_path=''as $$
declare m public.messages;c public.conversations;s public.whatsapp_journey_settings;
begin
 select *into m from public.messages where id=p_message;
 if m.journey_version is null then return private.inbox_delivery_error_before_journey(p_message);end if;
 select *into c from public.conversations where id=m.conversation_id;select *into s from public.whatsapp_journey_settings where property_id=m.property_id;
 if not private.tenant_is_active(m.tenant_id)or not s.enabled or s.version is distinct from m.journey_version then return 'Guest journey paused or changed.';end if;
 if private.is_opted_out(m.property_id,c.wa_contact_id)then return 'Guest opted out.';end if;
 if c.status<>'open'or c.human_handoff and m.journey_purpose<>'handoff'or c.last_inbound_at is null or c.last_inbound_at<now()-interval '24 hours'then return 'Guest reply window closed or reception is handling this conversation.';end if;
 if not exists(select 1 from public.whatsapp_connections where id=c.connection_id and phone_number_id=m.journey_sender and status='active')then return 'Hotel sender changed or disconnected.';end if;
 if m.journey_reservation is not null and m.journey_reservation is distinct from private.journey_stay(c.id)then return 'Guest booking or number changed.';end if;
 return null;
end $$;

create function public.whatsapp_journey_workspace(p_property uuid,p_reservation uuid default null)returns jsonb
language plpgsql stable security definer set search_path=''as $$
begin
 if not(private.has_permission(p_property,'staff.manage')or(p_reservation is not null and private.has_permission(p_property,'reservations.read')))then raise exception 'Hotel access required.'using errcode='42501';end if;
 return jsonb_build_object('settings',(select to_jsonb(s)from public.whatsapp_journey_settings s where property_id=p_property),
 'contact_permission',exists(select 1 from private.whatsapp_booking_contacts b where b.reservation_id=p_reservation and b.property_id=p_property),
 'document_error',case when exists(select 1 from public.reservations where id=p_reservation and property_id=p_property)then private.journey_document_error(p_reservation)end,
 'documents',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'doc_type',d.doc_type,'status',d.status,'created_at',d.created_at,'scanned_at',d.scanned_at)order by d.created_at desc)from public.guest_documents d where d.property_id=p_property and d.reservation_id=p_reservation and private.has_permission(p_property,'documents.review')),'[]'::jsonb),
 'can_review',private.has_permission(p_property,'documents.review'));
end $$;
revoke all on function public.save_whatsapp_journey(uuid,integer,boolean,integer,boolean),public.record_whatsapp_booking_contact(uuid,uuid,text,boolean),public.frontdesk_create_whatsapp(uuid,text,uuid,text,text,text,uuid,date,date,integer,integer,uuid,uuid,text,text,numeric,boolean,text),public.whatsapp_journey_workspace(uuid,uuid)from public,anon;
grant execute on function public.save_whatsapp_journey(uuid,integer,boolean,integer,boolean),public.record_whatsapp_booking_contact(uuid,uuid,text,boolean),public.frontdesk_create_whatsapp(uuid,text,uuid,text,text,text,uuid,date,date,integer,integer,uuid,uuid,text,text,numeric,boolean,text),public.whatsapp_journey_workspace(uuid,uuid)to authenticated;

-- Private helpers cannot be used as anonymous/service-role command endpoints.
revoke all on function private.journey_document_error(uuid),private.journey_checkin_guard(),private.whatsapp_automation_error(uuid),private.whatsapp_automation_error_before_journey(uuid),private.journey_stay(uuid),private.journey_button(uuid,uuid,text,text,jsonb),private.queue_journey_reply(uuid,uuid,text,text,jsonb,uuid),private.journey_buttons_payload(text,jsonb),private.journey_private_link(uuid,uuid,text,text),private.journey_consent(uuid,uuid,uuid,text),private.handle_whatsapp_journey(uuid,uuid,text,text),private.complete_guest_checkout(uuid,uuid),private.queue_whatsapp_guest_reply(uuid,uuid,text,boolean,uuid,text),private.queue_whatsapp_guest_reply_before_journey(uuid,uuid,text,boolean,uuid,text),private.inbox_delivery_error(uuid),private.inbox_delivery_error_before_journey(uuid)from public,anon,authenticated,service_role;
