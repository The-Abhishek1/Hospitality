-- Hotel onboarding secrets are application-encrypted; only backend roles can read ciphertext.
create table private.whatsapp_credentials (
 property_id uuid primary key references public.properties(id) on delete cascade,
 credentials_ref text not null unique, ciphertext text not null,
 updated_at timestamptz not null default now()
);
create table private.whatsapp_setup_sessions (
 id uuid primary key default gen_random_uuid(), property_id uuid not null references public.properties(id) on delete cascade,
 actor uuid not null references auth.users(id) on delete cascade,
 expires_at timestamptz not null default now()+interval '10 minutes', consumed boolean not null default false
);
create table public.whatsapp_connection_audit (
 id uuid primary key default gen_random_uuid(), property_id uuid not null references public.properties(id) on delete cascade,
 actor uuid, action text not null, created_at timestamptz not null default now()
);
alter table public.whatsapp_connection_audit enable row level security;
create policy whatsapp_connection_audit_read on public.whatsapp_connection_audit for select to authenticated using(private.has_permission(property_id,'staff.manage'));
revoke all on private.whatsapp_credentials,private.whatsapp_setup_sessions from public,anon,authenticated;

create function public.whatsapp_setup_context(p_property uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c public.whatsapp_connections;
begin
 if not private.has_permission(p_property,'staff.manage') then raise exception 'Hotel administrator access required' using errcode='42501'; end if;
 select * into c from public.whatsapp_connections where property_id=p_property;
 return jsonb_build_object('connection',case when c.id is null then null else jsonb_build_object('id',c.id,'phone_number_id',c.phone_number_id,'waba_id',c.waba_id,'display_phone',c.display_phone,'status',c.status,'managed',exists(select 1 from private.whatsapp_credentials where property_id=p_property))end);
end $$;
create function public.whatsapp_setup_begin(p_property uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare sid uuid;
begin
 perform public.whatsapp_setup_context(p_property);
 delete from private.whatsapp_setup_sessions where expires_at<now();
 update private.whatsapp_setup_sessions set consumed=true where property_id=p_property and actor=auth.uid();
 insert into private.whatsapp_setup_sessions(property_id,actor)values(p_property,auth.uid())returning id into sid;
 return sid;
end $$;

-- Recheck the initiating administrator at commit time, not just at popup launch.
create function private.whatsapp_actor_allowed(p_property uuid,p_actor uuid) returns boolean
language plpgsql security definer set search_path='' as $$
declare claims text; allowed boolean;
begin
 claims:=current_setting('request.jwt.claims',true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',p_actor,'role','authenticated')::text,true);
 allowed:=private.has_permission(p_property,'staff.manage');
 perform set_config('request.jwt.claims',coalesce(claims,''),true);
 return allowed;
end $$;

create function public.whatsapp_setup_claim(p_session uuid,p_actor uuid) returns uuid
language plpgsql security definer set search_path=''as $$
declare s private.whatsapp_setup_sessions;
begin
 select * into s from private.whatsapp_setup_sessions where id=p_session for update;
 if s.id is null or s.actor<>p_actor or s.consumed or s.expires_at<now()or not private.whatsapp_actor_allowed(s.property_id,p_actor)then raise exception 'Setup expired or already attempted'using errcode='42501';end if;
 update private.whatsapp_setup_sessions set consumed=true where id=p_session;
 return s.property_id;
end $$;
create function public.whatsapp_setup_commit(p_session uuid,p_actor uuid,p_phone text,p_waba text,p_display text,p_ciphertext text) returns uuid
language plpgsql security definer set search_path='' as $$
declare s private.whatsapp_setup_sessions;c public.whatsapp_connections;cid uuid;ref text;tenant uuid;
begin
 select * into s from private.whatsapp_setup_sessions where id=p_session for update;
 if s.id is null or s.actor<>p_actor or not s.consumed or s.expires_at<now() or not private.whatsapp_actor_allowed(s.property_id,p_actor)then raise exception 'Setup expired or access changed' using errcode='42501';end if;
 select tenant_id into tenant from public.properties where id=s.property_id for update;
 select * into c from public.whatsapp_connections where property_id=s.property_id for update;
 if c.id is not null and(c.phone_number_id<>p_phone or c.waba_id<>p_waba)then raise exception 'Reconnect the existing number, or connect a different number to a separate hotel.'using errcode='22023';end if;
 if p_phone is null or p_waba is null or p_ciphertext is null or p_phone!~'^[0-9]{5,30}$'or p_waba!~'^[0-9]{5,30}$'or length(p_ciphertext)not between 40 and 20000 then raise exception 'Invalid connection data'using errcode='22023';end if;
 ref:='managed:'||s.property_id::text;
 insert into public.whatsapp_connections(tenant_id,property_id,phone_number_id,waba_id,display_phone,credentials_ref,status)
 values(tenant,s.property_id,p_phone,p_waba,p_display,ref,'active')
 on conflict(property_id)do update set display_phone=excluded.display_phone,credentials_ref=excluded.credentials_ref,status='active' returning id into cid;
 insert into private.whatsapp_credentials(property_id,credentials_ref,ciphertext)values(s.property_id,ref,p_ciphertext)
 on conflict(property_id)do update set ciphertext=excluded.ciphertext,credentials_ref=excluded.credentials_ref,updated_at=now();
 delete from private.whatsapp_setup_sessions where id=s.id;
 insert into public.whatsapp_connection_audit(property_id,actor,action)values(s.property_id,p_actor,'connected');
 return cid;
end $$;

create function public.whatsapp_delivery_credential(p_reference text) returns text
language sql security definer set search_path='' as $$
 select k.ciphertext from private.whatsapp_credentials k join public.whatsapp_connections c on c.property_id=k.property_id and c.credentials_ref=k.credentials_ref
 where k.credentials_ref=p_reference and c.status='active'and private.tenant_is_active(c.tenant_id)
$$;
create function public.whatsapp_setup_disconnect(p_property uuid)returns void
language plpgsql security definer set search_path='' as $$
begin
 perform public.whatsapp_setup_context(p_property);
 perform 1 from public.properties where id=p_property for update;
 update public.whatsapp_connections set status='disabled' where property_id=p_property;
 delete from private.whatsapp_credentials where property_id=p_property;
 update private.whatsapp_setup_sessions set consumed=true where property_id=p_property;
 insert into public.whatsapp_connection_audit(property_id,actor,action)values(p_property,auth.uid(),'disconnected');
end $$;

-- Existing manual setup must not overwrite an encrypted managed connection or its history.
create function private.whatsapp_connection_guard()returns trigger language plpgsql security definer set search_path=''as $$
begin
 if tg_op='UPDATE'and(new.phone_number_id<>old.phone_number_id or new.waba_id<>old.waba_id)and(current_setting('role',true)not in('service_role','none')or exists(select 1 from private.whatsapp_credentials where property_id=old.property_id))then
  raise exception 'A sender cannot be replaced on an existing connection.'using errcode='22023';
 end if;
 if current_setting('role',true)not in('service_role','none')and(new.credentials_ref like 'managed:%'or exists(select 1 from private.whatsapp_credentials where property_id=new.property_id))then
  if tg_op='INSERT'or new.status<>'disabled'or new.phone_number_id<>old.phone_number_id or new.waba_id<>old.waba_id or new.credentials_ref<>old.credentials_ref then
   raise exception 'Use secure WhatsApp onboarding to manage this connection.'using errcode='42501';
  end if;
 end if;
 return new;
end $$;
create trigger whatsapp_connection_guard before insert or update on public.whatsapp_connections for each row execute function private.whatsapp_connection_guard();
revoke all on function private.whatsapp_actor_allowed(uuid,uuid),private.whatsapp_connection_guard()from public,anon,authenticated;
revoke all on function public.whatsapp_setup_context(uuid),public.whatsapp_setup_begin(uuid),public.whatsapp_setup_disconnect(uuid),public.whatsapp_setup_claim(uuid,uuid),public.whatsapp_setup_commit(uuid,uuid,text,text,text,text),public.whatsapp_delivery_credential(text)from public,anon,authenticated;
grant execute on function public.whatsapp_setup_context(uuid),public.whatsapp_setup_begin(uuid),public.whatsapp_setup_disconnect(uuid)to authenticated;
grant execute on function public.whatsapp_setup_claim(uuid,uuid),public.whatsapp_setup_commit(uuid,uuid,text,text,text,text),public.whatsapp_delivery_credential(text)to service_role;
-- Do not let hotel clients bypass provider ownership verification with arbitrary IDs.
revoke execute on function public.connect_whatsapp(uuid,text,text,text,text),public.inbox_configure(uuid,text,text,text,text,text)from authenticated;
grant execute on function public.connect_whatsapp(uuid,text,text,text,text),public.inbox_configure(uuid,text,text,text,text,text)to service_role;
