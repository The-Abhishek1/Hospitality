-- A private stay link plus a signed WhatsApp inbound message proves stay access and number control.
alter table public.whatsapp_guest_authorizations add column source text not null default 'staff',add column consented_at timestamptz not null default now(),add column source_message_id uuid references public.messages(id),add column consent_version text not null default 'staff_record';
update public.whatsapp_guest_authorizations set consented_at=updated_at;
alter table public.whatsapp_marketing_permissions alter column actor_id drop not null;
alter table public.whatsapp_marketing_permissions add column source text not null default 'staff',add column source_message_id uuid references public.messages(id),add column consent_version text not null default 'staff_record';
alter table public.messages add column consent_confirmation_version integer,add column consent_confirmation_guest uuid references public.guests(id),add column consent_confirmation_offers boolean not null default false;
create table private.whatsapp_consent_challenges(
 id uuid primary key default gen_random_uuid(),property_id uuid not null references public.properties(id)on delete cascade,reservation_id uuid not null references public.reservations(id)on delete cascade,guest_id uuid not null references public.guests(id)on delete cascade,
 connection_id uuid not null references public.whatsapp_connections(id)on delete cascade,phone text not null,portal_token_hash text not null,code_hash text not null unique,request_id uuid not null,
 marketing boolean not null,created_at timestamptz not null default clock_timestamp(),expires_at timestamptz not null default(now()+interval '15 minutes'),consumed_at timestamptz,cancelled_at timestamptz,
 unique(reservation_id,request_id)
);
create index on private.whatsapp_consent_challenges(property_id,guest_id,created_at);
create table private.whatsapp_consent_inbound(message_id uuid primary key references public.messages(id)on delete cascade);
revoke all on private.whatsapp_consent_challenges,private.whatsapp_consent_inbound from public,anon,authenticated,service_role;

create function private.revoke_whatsapp_consent(p_property uuid,p_phone text,p_purpose text,p_source text,p_message uuid default null)returns void
language plpgsql security definer set search_path=''as $$
declare tenant uuid;
begin
 select tenant_id into tenant from public.properties where id=p_property;
 if p_purpose='both'and p_source='guest_portal'then insert into public.consent_records(property_id,tenant_id,wa_contact_id,status,source)values(p_property,tenant,p_phone,'opted_out','guest_portal');end if;
 if p_purpose in('updates','both')then
  update public.whatsapp_guest_authorizations set status='revoked',version=version+1,updated_at=clock_timestamp(),source=p_source,source_message_id=p_message,updated_by=null where property_id=p_property and wa_contact_id=p_phone and status='granted';
 end if;
 if p_purpose in('marketing','both')and coalesce((select status from public.whatsapp_marketing_permissions where property_id=p_property and wa_contact_id=p_phone order by recorded_at desc,id desc limit 1),'')='granted'then
  insert into public.whatsapp_marketing_permissions(property_id,tenant_id,wa_contact_id,status,evidence,actor_id,source,source_message_id)values(p_property,tenant,p_phone,'revoked','Guest withdrew marketing permission.',null,p_source,p_message);
 end if;
 update private.whatsapp_consent_challenges set cancelled_at=clock_timestamp()where property_id=p_property and phone=p_phone and consumed_at is null and cancelled_at is null;
 insert into public.whatsapp_automation_audit(property_id,tenant_id,action,details)values(p_property,tenant,'guest_consent_withdrawn',jsonb_build_object('purpose',p_purpose,'source',p_source,'message',p_message));
end $$;
revoke all on function private.revoke_whatsapp_consent(uuid,text,text,text,uuid)from public,anon,authenticated,service_role;

alter function public.portal_command(text,uuid,text,jsonb)rename to portal_command_before_consent;
revoke all on function public.portal_command_before_consent(text,uuid,text,jsonb)from public,anon,authenticated,service_role;
create function public.portal_command(p_token text,p_request uuid,p_action text,p_payload jsonb default '{}')returns jsonb
language plpgsql security definer set search_path=''as $$
declare r public.reservations;g public.guests;c public.whatsapp_connections;a public.whatsapp_guest_authorizations;phone text;code text;created timestamptz;offers boolean;purpose text;sender text;marketing text;
begin
 if p_action is null or p_action not in('consent_status','consent_start','consent_revoke','consent_cancel')then return public.portal_command_before_consent(p_token,p_request,p_action,p_payload);end if;
 r:=private.portal_reservation(p_token);select *into g from public.guests where id=r.guest_id;phone:=private.campaign_phone(g.phone);
 select *into c from public.whatsapp_connections where property_id=r.property_id and status='active';
 select *into a from public.whatsapp_guest_authorizations where property_id=r.property_id and guest_id=r.guest_id;
 select status into marketing from public.whatsapp_marketing_permissions where property_id=r.property_id and wa_contact_id=phone order by recorded_at desc,id desc limit 1;
 if p_action='consent_status'then return jsonb_build_object('updates',case when private.is_opted_out(r.property_id,phone)then'opted_out'when a.status='granted'and a.wa_contact_id is distinct from phone then'number_changed'else coalesce(a.status,'not_recorded')end,'marketing',case when private.is_opted_out(r.property_id,phone)then'revoked'else coalesce(marketing,'not_recorded')end,'verified_at',a.consented_at,'phone_hint',case when phone is not null then 'ending '||right(phone,4)else 'not recorded'end,'can_request',c.id is not null and phone is not null and r.status in('confirmed','checked_in'),'pending_until',(select max(expires_at)from private.whatsapp_consent_challenges where property_id=r.property_id and guest_id=r.guest_id and consumed_at is null and cancelled_at is null and expires_at>now()));end if;
 if p_request is null or p_payload is null or jsonb_typeof(p_payload)<>'object'or pg_column_size(p_payload)>2000 then raise exception 'Reload the messaging preferences form.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('guest-consent:'||r.property_id||':'||r.guest_id,0));
 if p_action='consent_cancel'then update private.whatsapp_consent_challenges set cancelled_at=clock_timestamp()where property_id=r.property_id and guest_id=r.guest_id and portal_token_hash=encode(sha256(convert_to(p_token,'utf8')),'hex')and consumed_at is null and cancelled_at is null;return jsonb_build_object('cancelled',true);end if;
 if p_action='consent_revoke'then
  purpose:=p_payload->>'purpose';if purpose is null or purpose not in('updates','marketing','both')or phone is null then raise exception 'Choose which messages to stop.'using errcode='22023';end if;
  -- Withdraw the previously verified contact as well if the hotel changed the guest number.
  if a.wa_contact_id is not null and a.wa_contact_id is distinct from phone then perform private.revoke_whatsapp_consent(r.property_id,a.wa_contact_id,purpose,'guest_portal');end if;
  perform private.revoke_whatsapp_consent(r.property_id,phone,purpose,'guest_portal');return jsonb_build_object('withdrawn',purpose);
 end if;
 if r.status not in('confirmed','checked_in')or c.id is null or phone is null then raise exception 'An open stay, recorded international guest number and connected hotel WhatsApp number are required. Contact reception.'using errcode='22023';end if;
 if p_payload->'updates'is distinct from 'true'::jsonb or jsonb_typeof(p_payload->'marketing')is distinct from 'boolean'then raise exception 'Choose whether to receive stay updates. Offers are optional.'using errcode='22023';end if;offers:=(p_payload->>'marketing')::boolean;
 if exists(select 1 from public.whatsapp_guest_authorizations where property_id=r.property_id and wa_contact_id=phone and guest_id<>g.id)or exists(select 1 from public.conversations where connection_id=c.id and wa_contact_id=phone and guest_id is not null and guest_id<>g.id)then raise exception 'This number is linked to a different guest. Reception must review the guest records.'using errcode='22023';end if;
 if exists(select 1 from private.whatsapp_consent_challenges where reservation_id=r.id and request_id=p_request)then return jsonb_build_object('already_requested',true);end if;
 if(select count(*)from private.whatsapp_consent_challenges where property_id=r.property_id and guest_id=g.id and created_at>now()-interval '1 hour')>=5 then raise exception 'Too many verification requests. Try again later or contact reception.'using errcode='54000';end if;
 sender:=regexp_replace(coalesce(c.display_phone,''),'[^0-9]','','g');if sender!~'^[1-9][0-9]{7,14}$'then raise exception 'Hotel WhatsApp sender details are unavailable. Contact reception.'using errcode='22023';end if;
 update private.whatsapp_consent_challenges set cancelled_at=clock_timestamp()where property_id=r.property_id and guest_id=g.id and consumed_at is null and cancelled_at is null;
 code:=encode(extensions.gen_random_bytes(32),'hex');created:=clock_timestamp();
 insert into private.whatsapp_consent_challenges(property_id,reservation_id,guest_id,connection_id,phone,portal_token_hash,code_hash,request_id,marketing,created_at)values(r.property_id,r.id,g.id,c.id,phone,encode(sha256(convert_to(p_token,'utf8')),'hex'),encode(sha256(convert_to(code,'utf8')),'hex'),p_request,offers,created);
 return jsonb_build_object('phone',sender,'message',case when offers then'I AGREE TO STAY UPDATES AND OFFERS 'else'I AGREE TO STAY UPDATES 'end||code,'created_at',created,'expires_at',now()+interval '15 minutes');
end $$;
revoke all on function public.portal_command(text,uuid,text,jsonb)from public,authenticated;grant execute on function public.portal_command(text,uuid,text,jsonb)to anon;

alter function public.ingest_whatsapp_inbound(text,text,text,text,text,text,text,jsonb,timestamptz)rename to ingest_whatsapp_inbound_before_consent;
revoke all on function public.ingest_whatsapp_inbound_before_consent(text,text,text,text,text,text,text,jsonb,timestamptz)from public,anon,authenticated,service_role;
create function public.ingest_whatsapp_inbound(p_phone_number_id text,p_event_key text,p_wa_contact_id text,p_contact_name text,p_wa_message_id text,p_type text,p_body text,p_payload jsonb,p_sent_at timestamptz default now())returns uuid
language plpgsql security definer set search_path=''as $$
declare cid uuid;mid uuid;c public.conversations;ch private.whatsapp_consent_challenges;r public.reservations;g public.guests;cmd text;code text;claimed uuid;ops text;
begin
 cid:=public.ingest_whatsapp_inbound_before_consent(p_phone_number_id,p_event_key,p_wa_contact_id,p_contact_name,p_wa_message_id,p_type,p_body,p_payload,p_sent_at);if cid is null then return null;end if;
 if p_type<>'text'then return cid;end if;cmd:=upper(trim(coalesce(p_body,'')));
 if cmd not in('STOP','UNSUBSCRIBE','STOP OFFERS','STOP MARKETING','STOP UPDATES','STOP STAY UPDATES')and cmd!~'^I AGREE TO STAY UPDATES( AND OFFERS)? [A-F0-9]{64}$'then return cid;end if;
 select *into c from public.conversations where id=cid;select id into mid from public.messages where conversation_id=cid and wa_message_id=p_wa_message_id and direction='in';if mid is null then return cid;end if;
 insert into private.whatsapp_consent_inbound(message_id)values(mid)on conflict do nothing returning message_id into claimed;if claimed is null then return cid;end if;
 delete from private.whatsapp_guest_inbound_jobs where message_id=mid;
 if cmd in('STOP','UNSUBSCRIBE','STOP OFFERS','STOP MARKETING','STOP UPDATES','STOP STAY UPDATES')then
  perform private.revoke_whatsapp_consent(c.property_id,c.wa_contact_id,case when cmd in('STOP OFFERS','STOP MARKETING')then'marketing'when cmd in('STOP UPDATES','STOP STAY UPDATES')then'updates'else'both'end,'whatsapp_keyword',mid);return cid;
 end if;
 code:=lower(right(cmd,64));select *into ch from private.whatsapp_consent_challenges where code_hash=encode(sha256(convert_to(code,'utf8')),'hex');
 if ch.id is null or ch.property_id<>c.property_id or ch.connection_id<>c.connection_id or ch.phone<>c.wa_contact_id or ch.consumed_at is not null or ch.cancelled_at is not null or ch.expires_at<=clock_timestamp()or ch.marketing<>(cmd like 'I AGREE TO STAY UPDATES AND OFFERS %')then return cid;end if;
 perform pg_advisory_xact_lock(hashtextextended('guest-consent:'||ch.property_id||':'||ch.guest_id,0));
 select *into ch from private.whatsapp_consent_challenges where id=ch.id for update;
 if ch.cancelled_at is not null or ch.consumed_at is not null or ch.expires_at<=clock_timestamp()then return cid;end if;
 select *into r from public.reservations where id=ch.reservation_id and property_id=ch.property_id;select *into g from public.guests where id=r.guest_id;
 if r.status not in('confirmed','checked_in')or r.guest_id is distinct from ch.guest_id or private.campaign_phone(g.phone)is distinct from ch.phone or not private.tenant_is_active(r.tenant_id)or not exists(select 1 from public.guest_access_tokens where token_hash=ch.portal_token_hash and reservation_id=r.id and revoked_at is null and expires_at>now())or(c.guest_id is not null and c.guest_id<>g.id)or exists(select 1 from public.whatsapp_guest_authorizations where property_id=c.property_id and wa_contact_id=ch.phone and guest_id<>g.id)then return cid;end if;
 -- A guest's fresh, verified agreement may resume messaging. A prior STOP cancelled every older challenge.
 update private.whatsapp_consent_challenges set consumed_at=clock_timestamp()where id=ch.id;
 update public.conversations set guest_id=g.id where id=cid;
 insert into public.consent_records(property_id,tenant_id,wa_contact_id,status,source)values(c.property_id,c.tenant_id,c.wa_contact_id,'opted_in','verified_guest');
 insert into public.whatsapp_guest_authorizations(property_id,tenant_id,guest_id,wa_contact_id,conversation_id,status,evidence,source,consented_at,source_message_id,consent_version)
 values(c.property_id,c.tenant_id,g.id,ch.phone,cid,'granted','Guest agreed on a private stay page and confirmed from their WhatsApp number.','guest_whatsapp',clock_timestamp(),mid,'stay_updates_v1')
 on conflict(property_id,guest_id)do update set wa_contact_id=excluded.wa_contact_id,conversation_id=excluded.conversation_id,status='granted',evidence=excluded.evidence,source=excluded.source,consented_at=excluded.consented_at,source_message_id=excluded.source_message_id,consent_version=excluded.consent_version,version=whatsapp_guest_authorizations.version+1,updated_at=clock_timestamp(),updated_by=null;
 if ch.marketing then insert into public.whatsapp_marketing_permissions(property_id,tenant_id,wa_contact_id,status,evidence,actor_id,source,source_message_id,consent_version)values(c.property_id,c.tenant_id,ch.phone,'granted','Guest separately agreed to hotel offers, review requests and marketing on the stay page and confirmed from their WhatsApp number.',null,'guest_whatsapp',mid,'hotel_marketing_v1');end if;
 update public.whatsapp_automation_events set next_check_at=now()where property_id=c.property_id and guest_id=g.id and state='blocked'and expires_at>now();
 insert into public.whatsapp_automation_audit(property_id,tenant_id,action,details)values(c.property_id,c.tenant_id,'guest_consent_verified',jsonb_build_object('guest',g.id,'reservation',r.id,'source','guest_whatsapp','marketing',ch.marketing,'message',mid,'wording','stay_updates_v1','marketing_wording',case when ch.marketing then'hotel_marketing_v1'else null end));
 if not c.human_handoff then insert into public.messages(property_id,tenant_id,conversation_id,direction,type,body,status,consent_confirmation_version,consent_confirmation_guest,consent_confirmation_offers)values(c.property_id,c.tenant_id,cid,'out','text',case when ch.marketing then'Your WhatsApp stay updates and optional hotel offers are confirmed. Send STOP to stop all messages, STOP OFFERS to stop offers, or STOP UPDATES to stop stay updates.'else'Your WhatsApp stay updates are confirmed. Offers were not added by this confirmation. Send STOP to stop all messages or STOP UPDATES to stop stay updates.'end,'queued',(select version from public.whatsapp_guest_authorizations where property_id=c.property_id and guest_id=g.id),g.id,ch.marketing);end if;
 perform private.wake_whatsapp_guest_worker();return cid;
end $$;
revoke all on function public.ingest_whatsapp_inbound(text,text,text,text,text,text,text,jsonb,timestamptz)from public,anon,authenticated;grant execute on function public.ingest_whatsapp_inbound(text,text,text,text,text,text,text,jsonb,timestamptz)to service_role;

-- Keep the recorded source accurate when staff resolve an exception manually.
create or replace function public.authorize_whatsapp_stay_updates(p_property uuid,p_reservation uuid,p_version integer,p_status text,p_evidence text,p_confirmed boolean)returns void
language plpgsql security definer set search_path=''as $$
declare r public.reservations;g public.guests;a public.whatsapp_guest_authorizations;w public.whatsapp_connections;phone text;cv uuid;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel administrator access required'using errcode='42501';end if;
 perform 1 from public.properties where id=p_property for update;
 select *into r from public.reservations where id=p_reservation and property_id=p_property;
 if r.id is null or p_status not in('granted','revoked')or p_confirmed is not true or length(trim(coalesce(p_evidence,'')))not between 10 and 1000 then raise exception 'Select a stay and record the guest’s confirmed number and permission evidence.'using errcode='22023';end if;
 select *into g from public.guests where id=r.guest_id and tenant_id=r.tenant_id;
 select *into a from public.whatsapp_guest_authorizations where property_id=p_property and guest_id=g.id;
 if coalesce(a.version,0)<>p_version then raise exception 'Permission changed. Refresh before saving.'using errcode='40001';end if;
 if p_status='revoked'and a.id is not null then
  update public.whatsapp_guest_authorizations set status='revoked',source='staff',source_message_id=null,consent_version='staff_record',evidence=trim(p_evidence),version=version+1,updated_at=now(),updated_by=auth.uid()where id=a.id;
 else
  phone:=private.campaign_phone(g.phone);select *into w from public.whatsapp_connections where property_id=p_property and status='active';
  if phone is null or w.id is null then raise exception 'An active hotel sender and a guest phone with country code are required.'using errcode='22023';end if;
  insert into public.conversations(tenant_id,property_id,connection_id,wa_contact_id,contact_name,guest_id)values(r.tenant_id,p_property,w.id,phone,g.full_name,g.id)
  on conflict(connection_id,wa_contact_id)do nothing returning id into cv;
  if cv is null then select id into cv from public.conversations where connection_id=w.id and wa_contact_id=phone and(guest_id is null or guest_id=g.id);end if;
  if cv is null then raise exception 'This contact is linked to another guest. Review the guest identity first.'using errcode='22023';end if;
  update public.conversations set guest_id=g.id where id=cv;
  insert into public.whatsapp_guest_authorizations(property_id,tenant_id,guest_id,wa_contact_id,conversation_id,status,evidence,updated_by)
  values(p_property,r.tenant_id,g.id,phone,cv,p_status,trim(p_evidence),auth.uid())on conflict(property_id,guest_id)do update set source='staff',consented_at=clock_timestamp(),source_message_id=null,consent_version='staff_record',wa_contact_id=excluded.wa_contact_id,conversation_id=excluded.conversation_id,status=excluded.status,evidence=excluded.evidence,version=whatsapp_guest_authorizations.version+1,updated_at=now(),updated_by=auth.uid();
 end if;
 insert into public.whatsapp_automation_audit(property_id,tenant_id,actor,action,details)values(p_property,r.tenant_id,auth.uid(),'stay_permission',jsonb_build_object('guest',g.id,'status',p_status,'evidence',trim(p_evidence)));
end $$;


create function public.whatsapp_consent_workspace(p_property uuid,p_filter text default 'all',p_query text default '',p_page integer default 1)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare result jsonb;pg integer:=greatest(1,least(10000,coalesce(p_page,1)));
begin
 if not private.has_permission(p_property,'staff.manage')or not exists(select 1 from public.properties p where p.id=p_property and private.tenant_is_active(p.tenant_id))then raise exception 'Hotel administrator access required.'using errcode='42501';end if;
 if p_filter is null or p_filter not in('all','attention','granted','opted_out')then raise exception 'Choose a consent filter.'using errcode='22023';end if;
 with recent as(select distinct on(r.guest_id)r.guest_id,r.id as reservation_id,g.full_name,g.phone,r.check_in,r.check_out from public.reservations r join public.guests g on g.id=r.guest_id where r.property_id=p_property order by r.guest_id,r.created_at desc,r.id desc),
 contacts as(select x.*,private.campaign_phone(x.phone)as normalized,a.source,a.consented_at,a.status as saved_status,a.wa_contact_id,a.updated_at,private.is_opted_out(p_property,private.campaign_phone(x.phone))as stopped,
 (select status from public.whatsapp_marketing_permissions m where m.property_id=p_property and m.wa_contact_id=private.campaign_phone(x.phone)order by recorded_at desc,id desc limit 1)as marketing,
 exists(select 1 from private.whatsapp_consent_challenges h where h.property_id=p_property and h.guest_id=x.guest_id and h.consumed_at is null and h.cancelled_at is null and h.expires_at>now())as pending
 from recent x left join public.whatsapp_guest_authorizations a on a.property_id=p_property and a.guest_id=x.guest_id),
 rows as(select c.*,case when stopped then'opted_out'when normalized is null then'missing_phone'when saved_status='granted'and wa_contact_id<>normalized then'number_changed'when saved_status='granted'then'granted'when pending then'pending'when saved_status='revoked'then'withdrawn'else'not_recorded'end as state from contacts c),
 filtered as(select *from rows where(p_filter='all'or p_filter='attention'and state in('missing_phone','number_changed','pending','not_recorded')or p_filter='granted'and state='granted'or p_filter='opted_out'and state in('opted_out','withdrawn'))and(coalesce(p_query,'')=''or full_name ilike '%'||left(p_query,100)||'%'or phone ilike '%'||left(p_query,100)||'%'))
 select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(z))from(select guest_id,reservation_id,full_name,phone,check_in,check_out,state,source,consented_at,updated_at,case when stopped then'revoked'else coalesce(marketing,'not_recorded')end as marketing from filtered order by full_name,guest_id limit 25 offset(pg-1)*25)z),'[]'),
 'total',(select count(*)from filtered),'page',pg,'counts',jsonb_build_object('all',(select count(*)from rows),'granted',(select count(*)from rows where state='granted'),'attention',(select count(*)from rows where state in('missing_phone','number_changed','pending','not_recorded')),'opted_out',(select count(*)from rows where state in('opted_out','withdrawn'))))into result;
 return result;
end $$;
revoke all on function public.whatsapp_consent_workspace(uuid,text,text,integer)from public,anon;grant execute on function public.whatsapp_consent_workspace(uuid,text,text,integer)to authenticated;

-- A queued confirmation must not outlive a later withdrawal or change of preferences.
alter function private.inbox_delivery_error(uuid)rename to inbox_delivery_error_before_consent;
revoke all on function private.inbox_delivery_error_before_consent(uuid)from public,anon,authenticated,service_role;
create function private.inbox_delivery_error(p_message uuid)returns text language plpgsql stable security definer set search_path=''as $$
declare why text;m public.messages;c public.conversations;
begin
 why:=private.inbox_delivery_error_before_consent(p_message);if why is not null then return why;end if;
 select *into m from public.messages where id=p_message;
 if m.consent_confirmation_version is not null then
  select *into c from public.conversations where id=m.conversation_id;
  if c.human_handoff or c.status<>'open'then return 'Conversation is under human handling or resolved.';end if;
  if not exists(select 1 from public.whatsapp_guest_authorizations a join public.guests g on g.id=a.guest_id where a.property_id=m.property_id and a.guest_id=m.consent_confirmation_guest and a.conversation_id=c.id and a.status='granted'and a.version=m.consent_confirmation_version and a.wa_contact_id=c.wa_contact_id and private.campaign_phone(g.phone)=c.wa_contact_id)then return 'Guest consent changed after this confirmation was queued.';end if;
  if m.consent_confirmation_offers and private.campaign_contact_error(m.property_id,c.wa_contact_id)is not null then return 'Marketing permission changed after this confirmation was queued.';end if;
 end if;
 return null;
end $$;
revoke all on function private.inbox_delivery_error(uuid)from public,anon,authenticated,service_role;
