-- Existing WhatsApp Business app numbers keep their registration and mobile app.
alter table public.whatsapp_connections add column connection_mode text not null default 'cloud_api' check(connection_mode in('cloud_api','coexistence'));
alter table private.whatsapp_setup_sessions add column connection_mode text not null default 'cloud_api',add column expected_phone text;
alter table public.messages add column whatsapp_source text not null default 'api' check(whatsapp_source in('api','business_app','history'));
alter table public.messages add column whatsapp_changed_at timestamptz;
alter table public.whatsapp_connection_audit alter column created_at set default clock_timestamp();

create table private.whatsapp_coexistence_sync(
 connection_id uuid not null references public.whatsapp_connections(id)on delete cascade,
 kind text not null check(kind in('smb_app_state_sync','history')),
 state text not null default 'pending' check(state in('pending','sending','requested','complete','declined','failed','unknown')),
 request_id text,lease uuid,claimed_at timestamptz,error text,can_retry boolean not null default false,progress int not null default 0 check(progress between 0 and 100),
 imported int not null default 0,created_at timestamptz not null default now(),deadline timestamptz not null default now()+interval '24 hours',
 primary key(connection_id,kind)
);
create table private.whatsapp_coexistence_events(
 id uuid primary key default gen_random_uuid(),connection_id uuid not null references public.whatsapp_connections(id)on delete cascade,
 event_key text not null,field text not null,payload jsonb not null,cursor int not null default 0,
 state text not null default 'pending' check(state in('pending','processing','done','failed')),
 lease uuid,claimed_at timestamptz,attempts int not null default 0,error text,created_at timestamptz not null default now(),
 unique(connection_id,event_key)
);
create index on private.whatsapp_coexistence_events(state,created_at);
create table private.whatsapp_coexistence_contacts(
 connection_id uuid not null references public.whatsapp_connections(id)on delete cascade,contact_key text not null,
 phone text,full_name text,removed boolean not null default false,changed_at timestamptz not null,
 primary key(connection_id,contact_key)
);
create table private.whatsapp_coexistence_unmatched(
 connection_id uuid not null references public.whatsapp_connections(id)on delete cascade,message_key text not null,
 record jsonb not null,created_at timestamptz not null default now(),primary key(connection_id,message_key)
);
revoke all on private.whatsapp_coexistence_sync,private.whatsapp_coexistence_events,private.whatsapp_coexistence_contacts,private.whatsapp_coexistence_unmatched from public,anon,authenticated,service_role;
create table private.whatsapp_coexistence_mutations(connection_id uuid not null references public.whatsapp_connections(id)on delete cascade,target text not null,changed_at timestamptz not null,revoked boolean not null,record jsonb not null,primary key(connection_id,target));
revoke all on private.whatsapp_coexistence_mutations from public,anon,authenticated,service_role;

create function public.whatsapp_setup_begin_v2(p_property uuid,p_mode text,p_phone text default null)returns uuid
language plpgsql security definer set search_path=''as $$
declare sid uuid;c public.whatsapp_connections;phone text:=regexp_replace(coalesce(p_phone,''),'[[:space:]()+.\-]','','g');
begin
 perform public.whatsapp_setup_context(p_property);
 if p_mode is null or p_mode not in('cloud_api','coexistence')then raise exception 'Choose how to connect this number.'using errcode='22023';end if;
 select *into c from public.whatsapp_connections where property_id=p_property;
 if c.id is not null and c.connection_mode<>p_mode then raise exception 'Reconnect using this hotel’s existing connection type.'using errcode='22023';end if;
 if c.id is not null and p_mode='coexistence'then phone:=regexp_replace(coalesce(c.display_phone,''),'[^0-9]','','g');end if;
 if p_mode='coexistence'and phone!~'^[1-9][0-9]{6,14}$'then raise exception 'Enter the existing business number with its country code.'using errcode='22023';end if;
 sid:=public.whatsapp_setup_begin(p_property);
 update private.whatsapp_setup_sessions set connection_mode=p_mode,expected_phone=case when p_mode='coexistence'then phone end where id=sid;
 return sid;
end $$;
create function public.whatsapp_setup_claim_v2(p_session uuid,p_actor uuid)returns jsonb
language plpgsql security definer set search_path=''as $$
declare pid uuid;s private.whatsapp_setup_sessions;
begin
 pid:=public.whatsapp_setup_claim(p_session,p_actor);
 select *into s from private.whatsapp_setup_sessions where id=p_session;
 return jsonb_build_object('property_id',pid,'mode',s.connection_mode,'expected_phone',s.expected_phone);
end $$;

alter function public.whatsapp_setup_commit(uuid,uuid,text,text,text,text)rename to whatsapp_setup_commit_before_coexistence;
revoke all on function public.whatsapp_setup_commit_before_coexistence(uuid,uuid,text,text,text,text)from public,anon,authenticated,service_role;
create function public.whatsapp_setup_commit(p_session uuid,p_actor uuid,p_phone text,p_waba text,p_display text,p_ciphertext text)returns uuid
language plpgsql security definer set search_path=''as $$
declare s private.whatsapp_setup_sessions;cid uuid;c public.whatsapp_connections;new_cycle boolean:=false;
begin
 select *into s from private.whatsapp_setup_sessions where id=p_session for update;
 if s.id is null then raise exception 'Setup expired.'using errcode='42501';end if;
 select *into c from public.whatsapp_connections where property_id=s.property_id;
 if c.id is not null and s.connection_mode='coexistence'then
  select exists(select 1 from public.whatsapp_connection_audit a where a.property_id=s.property_id and a.action in('meta_partner_removed','meta_account_offboarded')and a.created_at>coalesce((select max(z.created_at)from public.whatsapp_connection_audit z where z.property_id=s.property_id and z.action='connected'),c.created_at))into new_cycle;
 end if;
 if c.id is not null and c.connection_mode<>s.connection_mode then raise exception 'Connection type changed. Start again.'using errcode='22023';end if;
 if s.connection_mode='coexistence'and regexp_replace(coalesce(p_display,''),'[^0-9]','','g')is distinct from s.expected_phone then raise exception 'The authorized number does not match this setup.'using errcode='22023';end if;
 cid:=public.whatsapp_setup_commit_before_coexistence(p_session,p_actor,p_phone,p_waba,p_display,p_ciphertext);
 update public.whatsapp_connections set connection_mode=s.connection_mode where id=cid;
 if s.connection_mode='coexistence'then
  -- Local token renewal is not a new Meta onboarding cycle. A signed external
  -- offboarding event followed by verified re-onboarding is; keep messages but
  -- start the mandatory one-time requests for that new cycle only.
  if new_cycle then delete from private.whatsapp_coexistence_events where connection_id=cid;delete from private.whatsapp_coexistence_sync where connection_id=cid;end if;
  insert into private.whatsapp_coexistence_sync(connection_id,kind)values(cid,'smb_app_state_sync'),(cid,'history')on conflict do nothing;
 end if;
 return cid;
end $$;

alter function public.whatsapp_setup_context(uuid)rename to whatsapp_setup_context_before_coexistence;
revoke all on function public.whatsapp_setup_context_before_coexistence(uuid)from public,anon,authenticated,service_role;
create function public.whatsapp_setup_context(p_property uuid)returns jsonb
language plpgsql security definer set search_path=''as $$
declare d jsonb;c public.whatsapp_connections;sync jsonb;
begin
 d:=public.whatsapp_setup_context_before_coexistence(p_property);
 select *into c from public.whatsapp_connections where property_id=p_property;
 if c.id is null then return d;end if;
 select jsonb_agg(jsonb_build_object('kind',kind,'state',state,'progress',progress,'imported',imported,'error',error,'can_retry',can_retry,'deadline',deadline)order by kind)into sync from private.whatsapp_coexistence_sync where connection_id=c.id;
 return d||jsonb_build_object('connection',(d->'connection')||jsonb_build_object('mode',c.connection_mode),
  'coexistence',case when c.connection_mode='coexistence'then jsonb_build_object('sync',coalesce(sync,'[]'),
   'pending_events',(select count(*)from private.whatsapp_coexistence_events where connection_id=c.id and state in('pending','processing')),
   'failed_events',(select count(*)from private.whatsapp_coexistence_events where connection_id=c.id and state='failed'),
   'unmatched',(select count(*)from private.whatsapp_coexistence_unmatched where connection_id=c.id))end);
end $$;

-- Authenticated provider events are persisted before acknowledging large history deliveries.
create function public.enqueue_whatsapp_coexistence(p_phone text,p_waba text,p_field text,p_payload jsonb)returns uuid
language plpgsql security definer set search_path=''as $$
declare c public.whatsapp_connections;eid uuid;key text;
begin
 select w.*into c from public.whatsapp_connections w where w.phone_number_id=p_phone and w.waba_id=p_waba and w.connection_mode='coexistence'and w.status='active'and private.tenant_is_active(w.tenant_id);
 if c.id is null then return null;end if;
 if p_field not in('history','smb_app_state_sync','smb_message_echoes')or jsonb_typeof(p_payload)<>'object'then raise exception 'Invalid coexistence event.'using errcode='22023';end if;
 key:=p_field||':'||encode(extensions.digest(convert_to(p_payload::text,'UTF8'),'sha256'),'hex');
 insert into private.whatsapp_coexistence_events(connection_id,event_key,field,payload)values(c.id,key,p_field,p_payload)on conflict do nothing returning id into eid;
 return eid;
end $$;
create function public.whatsapp_coexistence_account_update(p_waba text,p_event text,p_at timestamptz default now())returns void
language plpgsql security definer set search_path=''as $$
begin
 if p_event not in('PARTNER_REMOVED','ACCOUNT_OFFBOARDED')then return;end if;
 -- Removal is account-level: stop every sender shared by that account, never another WABA.
 delete from private.whatsapp_credentials where property_id in(select w.property_id from public.whatsapp_connections w where w.waba_id=p_waba and coalesce((select max(a.created_at)from public.whatsapp_connection_audit a where a.property_id=w.property_id and a.action='connected'),w.created_at)<=p_at);
 update public.whatsapp_connections w set status='disabled'where w.waba_id=p_waba and coalesce((select max(a.created_at)from public.whatsapp_connection_audit a where a.property_id=w.property_id and a.action='connected'),w.created_at)<=p_at;
 update private.whatsapp_setup_sessions set consumed=true where property_id in(select w.property_id from public.whatsapp_connections w where w.waba_id=p_waba and w.status='disabled'and coalesce((select max(a.created_at)from public.whatsapp_connection_audit a where a.property_id=w.property_id and a.action='connected'),w.created_at)<=p_at);
 insert into public.whatsapp_connection_audit(property_id,action)select w.property_id,'meta_'||lower(p_event)from public.whatsapp_connections w where w.waba_id=p_waba and w.status='disabled'and coalesce((select max(a.created_at)from public.whatsapp_connection_audit a where a.property_id=w.property_id and a.action='connected'),w.created_at)<=p_at;
end $$;

create function private.apply_whatsapp_coexistence_mutation(p_connection uuid,p_message text)returns void
language plpgsql security definer set search_path=''as $$
declare change private.whatsapp_coexistence_mutations;c public.whatsapp_connections;t text;b text;
begin
 select *into change from private.whatsapp_coexistence_mutations where connection_id=p_connection and target=p_message;
 if change.target is null then return;end if;
 select *into c from public.whatsapp_connections where id=p_connection;
 t:=case when change.revoked then'revoked'else left(coalesce(change.record->>'type','unknown'),40)end;
 b:=case when change.revoked then'[Message deleted in WhatsApp]'else left(coalesce(change.record#>>'{text,body}',change.record#>>array[t,'caption'],'['||t||']'),4096)end;
 update public.messages set type=t,body=b,whatsapp_changed_at=change.changed_at where property_id=c.property_id and wa_message_id=p_message and(whatsapp_changed_at is null or whatsapp_changed_at<=change.changed_at);
end $$;
create function public.route_whatsapp_coexistence_message(p_phone text,p_waba text,p_payload jsonb)returns boolean
language plpgsql security definer set search_path=''as $$
declare c public.whatsapp_connections;m public.messages;contact text;v_target text;stamp timestamptz;business text;message jsonb:=p_payload;initial timestamptz;
begin
 select *into c from public.whatsapp_connections where phone_number_id=p_phone and waba_id=p_waba and status='active'and connection_mode='coexistence'and private.tenant_is_active(tenant_id);
 if c.id is null then return false;end if;
 if coalesce(p_payload->>'timestamp','')!~'^[0-9]{1,11}$'then return true;end if;
 stamp:=to_timestamp((p_payload->>'timestamp')::double precision);
 if p_payload->>'type'in('edit','revoke')then
  v_target:=case when p_payload->>'type'='edit'then p_payload#>>'{edit,original_message_id}'else p_payload#>>'{revoke,original_message_id}'end;
  if coalesce(v_target,'')=''or length(v_target)>300 then return true;end if;
  insert into private.whatsapp_coexistence_mutations(connection_id,target,changed_at,revoked,record)values(c.id,v_target,stamp,p_payload->>'type'='revoke',coalesce(p_payload#>'{edit,message}','{}'))
  on conflict(connection_id,target)do update set changed_at=excluded.changed_at,revoked=excluded.revoked,record=excluded.record where not private.whatsapp_coexistence_mutations.revoked and excluded.changed_at>=private.whatsapp_coexistence_mutations.changed_at;
  perform private.apply_whatsapp_coexistence_mutation(c.id,v_target);return true;
 end if;
 if coalesce(p_payload->>'from','')!~'^[1-9][0-9]{6,14}$'and coalesce(p_payload->>'id','')<>''then
  insert into private.whatsapp_coexistence_unmatched(connection_id,message_key,record)values(c.id,left(p_payload->>'id',300),p_payload||jsonb_build_object('kind','live_contact_without_phone'))on conflict do nothing;
  return true;
 end if;
 select *into m from public.messages where property_id=c.property_id and wa_message_id=p_payload->>'id'and whatsapp_source='history';
 select min(created_at)into initial from private.whatsapp_coexistence_sync where connection_id=c.id;
 if m.id is null and p_payload->'history_context'is null and(initial is null or stamp>=initial)then return false;end if;
 business:=regexp_replace(c.display_phone,'[^0-9]','','g');
 if m.id is not null then
  select wa_contact_id into contact from public.conversations where id=m.conversation_id;
  message:=message||jsonb_build_object('from',case when m.direction='out'then business else contact end);
  if m.direction='out'then message:=message||jsonb_build_object('to',contact);end if;
 else contact:=case when regexp_replace(coalesce(p_payload->>'from',''),'[^0-9]','','g')=business then p_payload->>'to'else p_payload->>'from'end;end if;
 perform public.enqueue_whatsapp_coexistence(c.phone_number_id,c.waba_id,'history',jsonb_build_object('metadata',jsonb_build_object('display_phone_number',c.display_phone),'history',jsonb_build_array(jsonb_build_object('threads',jsonb_build_array(jsonb_build_object('id',contact,'messages',jsonb_build_array(message)))))));
 return true;
end $$;

create function public.claim_whatsapp_coexistence_sync()returns jsonb
language plpgsql security definer set search_path=''as $$
declare job private.whatsapp_coexistence_sync;c public.whatsapp_connections;
begin
 update private.whatsapp_coexistence_sync set state='unknown',error='The sync request outcome is unconfirmed. Check Meta before reconnecting; it was not sent again.'where state='sending'and claimed_at<now()-interval '3 minutes';
 update private.whatsapp_coexistence_sync set state='failed',error='The 24-hour sync-start window expired. Review the connection in Meta before onboarding again.'where state='pending'and deadline<now();
 select s.*into job from private.whatsapp_coexistence_sync s join public.whatsapp_connections w on w.id=s.connection_id
 where s.state='pending'and w.status='active'and w.connection_mode='coexistence'and private.tenant_is_active(w.tenant_id)
 and(s.kind='smb_app_state_sync'or exists(select 1 from private.whatsapp_coexistence_sync x where x.connection_id=s.connection_id and x.kind='smb_app_state_sync'and x.state in('requested','complete')))
 order by s.created_at,s.kind desc for update of s skip locked limit 1;
 if job.connection_id is null then return null;end if;
 update private.whatsapp_coexistence_sync set state='sending',lease=gen_random_uuid(),claimed_at=now()where connection_id=job.connection_id and kind=job.kind returning *into job;
 select *into c from public.whatsapp_connections where id=job.connection_id;
 return jsonb_build_object('connection_id',c.id,'phone',c.phone_number_id,'reference',c.credentials_ref,'kind',job.kind,'lease',job.lease);
end $$;
create function public.finish_whatsapp_coexistence_sync(p_connection uuid,p_kind text,p_lease uuid,p_state text,p_request text default null)returns void
language plpgsql security definer set search_path=''as $$
begin
 if p_state not in('requested','failed','unknown')then raise exception 'Invalid sync outcome.';end if;
 update private.whatsapp_coexistence_sync set state=case when state in('complete','declined')then state else p_state end,request_id=coalesce(left(p_request,200),request_id),can_retry=state not in('complete','declined')and p_state='failed',
 error=case when state in('complete','declined')then null else case p_state when'failed'then'Meta rejected the sync request. Check the connection and Coexistence permissions.'when'unknown'then'The sync request outcome is unconfirmed. It will not be sent again automatically.'end end
 where connection_id=p_connection and kind=p_kind and lease=p_lease;
end $$;

create function public.claim_whatsapp_coexistence_event()returns jsonb
language plpgsql security definer set search_path=''as $$
declare e private.whatsapp_coexistence_events;
begin
 update private.whatsapp_coexistence_events set state=case when attempts>=5 then'failed'else'pending'end,error='Import interrupted; already recorded messages remain deduplicated.'where state='processing'and claimed_at<now()-interval '3 minutes';
 select x.*into e from private.whatsapp_coexistence_events x join public.whatsapp_connections w on w.id=x.connection_id where x.state='pending'and w.status='active'and private.tenant_is_active(w.tenant_id)order by x.created_at for update of x skip locked limit 1;
 if e.id is null then return null;end if;
 update private.whatsapp_coexistence_events set state='processing',lease=gen_random_uuid(),claimed_at=now(),attempts=attempts+1 where id=e.id returning *into e;
 return jsonb_build_object('id',e.id,'lease',e.lease,'field',e.field,'payload',e.payload,'cursor',e.cursor);
end $$;

create function private.record_whatsapp_coexistence(c public.whatsapp_connections,r jsonb)returns int
language plpgsql security definer set search_path=''as $$
declare v_phone text:=r->>'phone';contact text:=r->>'contact_key';stamp timestamptz;cid uuid;mid uuid;changed int;src text:=r->>'source';
begin
 if coalesce(r->>'sent_at','')!~'^[0-9]{4}-'then return 0;end if;
 stamp:=least((r->>'sent_at')::timestamptz,clock_timestamp());
 if r->>'kind'='contact'then
  if contact is null or length(contact)>200 then return 0;end if;
  insert into private.whatsapp_coexistence_contacts(connection_id,contact_key,phone,full_name,removed,changed_at)
   values(c.id,contact,v_phone,left(r->>'name',200),coalesce((r->>'removed')::boolean,false),stamp)
   on conflict(connection_id,contact_key)do update set full_name=excluded.full_name,phone=excluded.phone,removed=excluded.removed,changed_at=excluded.changed_at where excluded.changed_at>=private.whatsapp_coexistence_contacts.changed_at;
  get diagnostics changed=row_count;
  if v_phone~'^[1-9][0-9]{6,14}$'then update public.conversations set contact_name=case when(r->>'removed')::boolean then null else left(r->>'name',200)end,version=version+1 where connection_id=c.id and wa_contact_id=v_phone and exists(select 1 from private.whatsapp_coexistence_contacts x where x.connection_id=c.id and x.contact_key=contact and x.changed_at=stamp);end if;
  return changed;
 end if;
 if r->>'kind'<>'message'or coalesce(r->>'id','')=''or length(r->>'id')>300 or src not in('history','business_app')or r->>'direction'not in('in','out')then return 0;end if;
 if v_phone is null or v_phone!~'^[1-9][0-9]{6,14}$'then
  insert into private.whatsapp_coexistence_unmatched(connection_id,message_key,record)values(c.id,left(r->>'id',300),r)on conflict do nothing;return 0;
 end if;
 select id into mid from public.messages where property_id=c.property_id and wa_message_id=r->>'id';
 if mid is not null then
  -- A later media history chunk may replace a placeholder, never a newer live/API message.
  update public.messages set type=left(r->>'type',40),body=left(r->>'body',4096)where id=mid and whatsapp_source='history'and type='media_placeholder'and r->>'type'<>'media_placeholder';
  perform private.apply_whatsapp_coexistence_mutation(c.id,r->>'id');
  return 0;
 end if;
 insert into public.conversations(tenant_id,property_id,connection_id,wa_contact_id,contact_name,status,last_message_at,human_handoff)
 values(c.tenant_id,c.property_id,c.id,v_phone,(select full_name from private.whatsapp_coexistence_contacts where connection_id=c.id and phone=v_phone and not removed order by changed_at desc limit 1),case when src='history'then'closed'else'open'end,stamp,src='business_app'and stamp>now()-interval '5 minutes')
 on conflict(connection_id,wa_contact_id)do update set last_message_at=greatest(public.conversations.last_message_at,excluded.last_message_at),
  human_handoff=public.conversations.human_handoff or excluded.human_handoff,
  status=case when src='business_app'and stamp>now()-interval '5 minutes'then'open'else public.conversations.status end,
  version=public.conversations.version+1 returning id into cid;
 insert into public.messages(tenant_id,property_id,conversation_id,direction,wa_message_id,type,body,status,created_at,whatsapp_source)
 values(c.tenant_id,c.property_id,cid,r->>'direction',r->>'id',left(r->>'type',40),left(r->>'body',4096),case when r->>'direction'='in'then'received'when r->>'status'in('sent','delivered','read')then r->>'status'else'sent'end,stamp,src)
 on conflict(property_id,wa_message_id)where wa_message_id is not null do nothing;
 get diagnostics changed=row_count;
 perform private.apply_whatsapp_coexistence_mutation(c.id,r->>'id');
 if src='business_app'and stamp>now()-interval '5 minutes'then
  update public.messages set status='failed',error='Reception replied from the WhatsApp Business app. Automatic replies are paused.'where conversation_id=cid and status='queued'and(automation_event_id is not null or guest_reply_to is not null);
 end if;
 -- No inbound ingest, service-window update, identity binding or consent is inferred here.
 return changed;
end $$;

create function public.apply_whatsapp_coexistence_batch(p_event uuid,p_lease uuid,p_offset int,p_records jsonb,p_next int,p_done boolean,p_summary jsonb default '{}')returns int
language plpgsql security definer set search_path=''as $$
declare e private.whatsapp_coexistence_events;c public.whatsapp_connections;r jsonb;n int:=0;v_progress int;
begin
 select *into e from private.whatsapp_coexistence_events where id=p_event for update;
 if e.id is null or e.lease is distinct from p_lease or e.state<>'processing'then raise exception 'Import lease expired.'using errcode='42501';end if;
 if e.cursor<>p_offset then return e.cursor;end if;
 if jsonb_typeof(p_records)<>'array'or jsonb_array_length(p_records)>200 or p_next<p_offset or p_next-p_offset<>jsonb_array_length(p_records)then raise exception 'Invalid import batch.'using errcode='22023';end if;
 select *into c from public.whatsapp_connections where id=e.connection_id and status='active'and connection_mode='coexistence'and private.tenant_is_active(tenant_id)for update;
 if c.id is null then raise exception 'Connection no longer active.'using errcode='42501';end if;
 for r in select value from jsonb_array_elements(p_records)loop n:=n+private.record_whatsapp_coexistence(c,r);end loop;
 if e.field='history'then
  update private.whatsapp_coexistence_sync set imported=imported+n where connection_id=c.id and kind='history';
 elsif e.field='smb_app_state_sync'then
  update private.whatsapp_coexistence_sync set imported=imported+n where connection_id=c.id and kind='smb_app_state_sync';
 end if;
 update private.whatsapp_coexistence_events set cursor=p_next,claimed_at=now(),attempts=case when p_next>p_offset then 0 else attempts end,state=case when p_done then'done'else'processing'end,payload=case when p_done then'{}'::jsonb else payload end where id=e.id;
 if p_done and e.field='history'then
  v_progress:=least(100,greatest(0,coalesce((p_summary->>'progress')::int,0)));
  update private.whatsapp_coexistence_sync set progress=greatest(v_progress,private.whatsapp_coexistence_sync.progress),
   state=case when p_summary->>'declined'='true'then'declined'when p_summary->>'error'='true'then'failed'when v_progress=100 then'complete'else state end,can_retry=false,
   error=case when p_summary->>'error'='true'then'Meta reported a history synchronization error. Review the connection.'when p_summary->>'declined'='true'or v_progress=100 then null else error end
   where connection_id=c.id and kind='history';
 elsif p_done and e.field='smb_app_state_sync'then
  update private.whatsapp_coexistence_sync set state='complete',error=null,can_retry=false where connection_id=c.id and kind='smb_app_state_sync';
 end if;
 return p_next;
end $$;

create function public.release_whatsapp_coexistence_event(p_event uuid,p_lease uuid,p_failed boolean default false)returns void
language plpgsql security definer set search_path=''as $$begin
 update private.whatsapp_coexistence_events set state=case when p_failed and attempts>=5 then'failed'else'pending'end,error=case when p_failed then'Import could not finish. Already recorded messages are retained.'end where id=p_event and lease=p_lease and state='processing';
end $$;
create function public.retry_whatsapp_coexistence(p_property uuid,p_kind text)returns void
language plpgsql security definer set search_path=''as $$
declare c public.whatsapp_connections;n int;
begin
 perform public.whatsapp_setup_context(p_property);
 select *into c from public.whatsapp_connections where property_id=p_property and status='active'and connection_mode='coexistence'for update;
 if c.id is null then raise exception 'Reconnect this hotel’s business app number first.'using errcode='22023';end if;
 if p_kind='events'then update private.whatsapp_coexistence_events set state='pending',attempts=0,error=null where connection_id=c.id and state='failed';
 elsif p_kind in('smb_app_state_sync','history')then
  update private.whatsapp_coexistence_sync set state='pending',lease=null,error=null,can_retry=false where connection_id=c.id and kind=p_kind and state='failed'and can_retry and request_id is null and deadline>now();get diagnostics n=row_count;
  if n=0 then raise exception 'This one-time request cannot be safely repeated. Check its Meta status first.'using errcode='22023';end if;
 else raise exception 'Invalid import request.'using errcode='22023';end if;
 perform private.invoke_whatsapp_coexistence_worker();
end $$;

-- Add source labels without changing the existing inbox authorization/query behavior.
alter function public.inbox_workspace(uuid,jsonb)rename to inbox_workspace_before_coexistence;
revoke all on function public.inbox_workspace_before_coexistence(uuid,jsonb)from public,anon,authenticated,service_role;
create function public.inbox_workspace(p_property uuid,p_filters jsonb default '{}')returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare d jsonb;messages jsonb;
begin
 d:=public.inbox_workspace_before_coexistence(p_property,p_filters);
 select coalesce(jsonb_agg(v||jsonb_build_object('whatsapp_source',m.whatsapp_source)order by n),'[]')into messages
 from jsonb_array_elements(d->'messages')with ordinality x(v,n)join public.messages m on m.id=(v->>'id')::uuid and m.property_id=p_property;
 return d||jsonb_build_object('messages',messages);
end $$;

create function private.invoke_whatsapp_coexistence_worker()returns bigint
language plpgsql security definer set search_path=''as $$
declare c private.whatsapp_worker_configuration;secret text;request bigint;
begin
 select *into c from private.whatsapp_worker_configuration where id=true and enabled;if c.id is null then return null;end if;
 if not exists(select 1 from private.whatsapp_coexistence_sync where state='pending')and not exists(select 1 from private.whatsapp_coexistence_events where state='pending')then return null;end if;
 select decrypted_secret into secret from vault.decrypted_secrets where id=c.secret_id;
 select net.http_post(url:=c.origin||'/functions/v1/whatsapp-coexistence-worker',headers:=jsonb_build_object('Content-Type','application/json','X-Worker-Secret',secret),body:='{}',timeout_milliseconds:=120000)into request;
 return request;
end $$;
create function public.wake_whatsapp_coexistence()returns void language plpgsql security definer set search_path=''as $$begin perform private.invoke_whatsapp_coexistence_worker();end $$;
revoke all on function private.record_whatsapp_coexistence(public.whatsapp_connections,jsonb),private.invoke_whatsapp_coexistence_worker(),private.apply_whatsapp_coexistence_mutation(uuid,text)from public,anon,authenticated,service_role;
revoke all on function public.whatsapp_setup_begin_v2(uuid,text,text),public.whatsapp_setup_claim_v2(uuid,uuid),public.whatsapp_setup_commit(uuid,uuid,text,text,text,text),public.whatsapp_setup_context(uuid),public.inbox_workspace(uuid,jsonb),public.enqueue_whatsapp_coexistence(text,text,text,jsonb),public.whatsapp_coexistence_account_update(text,text,timestamptz),public.claim_whatsapp_coexistence_sync(),public.finish_whatsapp_coexistence_sync(uuid,text,uuid,text,text),public.claim_whatsapp_coexistence_event(),public.apply_whatsapp_coexistence_batch(uuid,uuid,integer,jsonb,integer,boolean,jsonb),public.wake_whatsapp_coexistence(),public.route_whatsapp_coexistence_message(text,text,jsonb),public.release_whatsapp_coexistence_event(uuid,uuid,boolean),public.retry_whatsapp_coexistence(uuid,text)from public,anon,authenticated;
grant execute on function public.whatsapp_setup_begin_v2(uuid,text,text),public.whatsapp_setup_context(uuid),public.inbox_workspace(uuid,jsonb),public.retry_whatsapp_coexistence(uuid,text)to authenticated;
grant execute on function public.whatsapp_setup_claim_v2(uuid,uuid),public.whatsapp_setup_commit(uuid,uuid,text,text,text,text),public.enqueue_whatsapp_coexistence(text,text,text,jsonb),public.whatsapp_coexistence_account_update(text,text,timestamptz),public.claim_whatsapp_coexistence_sync(),public.finish_whatsapp_coexistence_sync(uuid,text,uuid,text,text),public.claim_whatsapp_coexistence_event(),public.apply_whatsapp_coexistence_batch(uuid,uuid,integer,jsonb,integer,boolean,jsonb),public.wake_whatsapp_coexistence(),public.route_whatsapp_coexistence_message(text,text,jsonb),public.release_whatsapp_coexistence_event(uuid,uuid,boolean)to service_role;
select cron.schedule('hospitality-whatsapp-coexistence','* * * * *','select private.invoke_whatsapp_coexistence_worker()');
notify pgrst,'reload schema';
