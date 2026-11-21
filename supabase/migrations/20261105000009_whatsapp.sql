-- Milestone 8: WhatsApp (official Cloud API). Each property connects its own WhatsApp Business number.
-- Webhook edge function verifies Meta's signature, then calls the service_role-only ingest functions.
-- Outbound is a durable Postgres queue (messages.status = queued) drained by a worker with retry/backoff;
-- this can be swapped for pgmq later without changing callers. Secrets live in Vault; only a reference is stored here.

insert into public.permissions (key, description) values ('whatsapp.use', 'Use the WhatsApp inbox: read, reply, claim conversations');
insert into public.role_permissions (role_id, permission_key)
select r.id, 'whatsapp.use' from public.roles r where r.tenant_id is null and r.key in ('front_desk', 'manager');

create table public.whatsapp_connections (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null unique,
  phone_number_id text not null unique,            -- Meta phone-number ID; routes webhooks to the property
  waba_id text not null, display_phone text,
  credentials_ref text not null,                   -- reference to a Vault secret, never the token itself
  status text not null default 'active' check (status in ('pending', 'active', 'disabled')),
  created_at timestamptz not null default now(),
  unique (id, property_id),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade
);

create table public.message_templates (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null,
  name text not null, language text not null default 'en',
  category text not null default 'utility' check (category in ('utility', 'authentication', 'marketing')),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  body text not null,
  unique (property_id, name, language),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade
);

create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null, connection_id uuid not null,
  wa_contact_id text not null, contact_name text, guest_id uuid,
  status text not null default 'open' check (status in ('open', 'closed')),
  assigned_to uuid,
  human_handoff boolean not null default false,    -- true = automation must stay silent
  last_inbound_at timestamptz,                     -- start of the 24h customer-service window
  last_message_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (id, property_id),
  unique (connection_id, wa_contact_id),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade,
  foreign key (connection_id, property_id) references public.whatsapp_connections (id, property_id) on delete cascade,
  foreign key (property_id, assigned_to) references public.property_memberships (property_id, user_id) on delete set null (assigned_to),
  foreign key (guest_id, tenant_id) references public.guests (id, tenant_id)
);
create index on public.conversations (property_id, status, last_message_at desc);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null, conversation_id uuid not null,
  direction text not null check (direction in ('in', 'out')),
  wa_message_id text,
  type text not null default 'text',
  body text,
  template_id uuid,
  status text not null check (status in ('received', 'queued', 'sending', 'sent', 'delivered', 'read', 'failed')),
  error text, attempts int not null default 0,
  next_attempt_at timestamptz not null default now(), locked_at timestamptz,
  sent_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (conversation_id, property_id) references public.conversations (id, property_id) on delete cascade,
  foreign key (template_id) references public.message_templates (id)
);
create unique index messages_wa_id_uq on public.messages (property_id, wa_message_id) where wa_message_id is not null;
create index messages_queue_idx on public.messages (next_attempt_at) where direction = 'out' and status in ('queued', 'sending');
create index on public.messages (conversation_id, created_at);

create table public.message_events (               -- raw webhook log; dedupes provider retries; service_role only
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null, connection_id uuid not null references public.whatsapp_connections(id) on delete cascade,
  event_key text not null, payload jsonb not null,
  received_at timestamptz not null default now(), processed_at timestamptz,
  unique (connection_id, event_key)
);

create table public.consent_records (               -- append-only; latest row wins
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null, wa_contact_id text not null,
  status text not null check (status in ('opted_in', 'opted_out')),
  source text not null, recorded_at timestamptz not null default clock_timestamp(),   -- not now(): ordering must hold within a transaction
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade
);
create index on public.consent_records (property_id, wa_contact_id, recorded_at desc);

alter table public.whatsapp_connections enable row level security;
alter table public.message_templates enable row level security;
alter table public.conversations enable row level security;
alter table public.messages enable row level security;
alter table public.message_events enable row level security;   -- no policies: service_role only
alter table public.consent_records enable row level security;

create policy wa_conn_select on public.whatsapp_connections for select to authenticated using (private.has_permission(property_id, 'staff.manage'));
create policy templates_select on public.message_templates for select to authenticated using (private.has_permission(property_id, 'whatsapp.use'));
create policy conversations_select on public.conversations for select to authenticated using (private.has_permission(property_id, 'whatsapp.use'));
create policy messages_select on public.messages for select to authenticated using (private.has_permission(property_id, 'whatsapp.use'));
create policy consent_select on public.consent_records for select to authenticated using (private.has_permission(property_id, 'whatsapp.use'));
-- No client write policies anywhere in this domain.

-- ---------- helpers ----------
create function private.is_opted_out(p_property uuid, p_contact text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select status = 'opted_out' from public.consent_records
                   where property_id = p_property and wa_contact_id = p_contact order by recorded_at desc, id desc limit 1), false)
$$;
create function private.wa_rank(s text) returns int language sql immutable as $$
  select case s when 'sent' then 1 when 'delivered' then 2 when 'read' then 3 else 0 end $$;
create function private.apply_wa_status(p_property uuid, p_wa_id text, p_status text, p_error text) returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update public.messages set status = p_status, error = p_error
   where property_id = p_property and wa_message_id = p_wa_id and direction = 'out'
     and case when p_status = 'failed' then private.wa_rank(status) < 2
              else private.wa_rank(p_status) > private.wa_rank(status) end;   -- out-of-order events never go backwards
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function private.is_opted_out(uuid, text), private.apply_wa_status(uuid, text, text, text) from public, anon;

-- ---------- service_role entry points (called by the webhook function and the worker) ----------
create function public.ingest_whatsapp_inbound(
  p_phone_number_id text, p_event_key text, p_wa_contact_id text, p_contact_name text,
  p_wa_message_id text, p_type text, p_body text, p_payload jsonb, p_sent_at timestamptz default now()
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c public.whatsapp_connections; v_ev uuid; v_conv uuid; v_kw text;
begin
  select * into c from public.whatsapp_connections where phone_number_id = p_phone_number_id and status = 'active';
  if not found then return null; end if;                       -- unknown number: acknowledge and ignore

  insert into public.message_events (tenant_id, property_id, connection_id, event_key, payload)
  values (c.tenant_id, c.property_id, c.id, p_event_key, p_payload)
  on conflict (connection_id, event_key) do nothing returning id into v_ev;
  if v_ev is null then return null; end if;                    -- duplicate delivery

  insert into public.conversations (tenant_id, property_id, connection_id, wa_contact_id, contact_name, last_inbound_at, last_message_at)
  values (c.tenant_id, c.property_id, c.id, p_wa_contact_id, p_contact_name, p_sent_at, p_sent_at)
  on conflict (connection_id, wa_contact_id) do update set
    contact_name = coalesce(excluded.contact_name, public.conversations.contact_name),
    last_inbound_at = greatest(coalesce(public.conversations.last_inbound_at, excluded.last_inbound_at), excluded.last_inbound_at),
    last_message_at = greatest(public.conversations.last_message_at, excluded.last_message_at),
    status = 'open'
  returning id into v_conv;

  insert into public.messages (tenant_id, property_id, conversation_id, direction, wa_message_id, type, body, status)
  values (c.tenant_id, c.property_id, v_conv, 'in', p_wa_message_id, p_type, p_body, 'received')
  on conflict (property_id, wa_message_id) where wa_message_id is not null do nothing;

  v_kw := upper(trim(coalesce(p_body, '')));
  if v_kw in ('STOP', 'UNSUBSCRIBE') then
    insert into public.consent_records (tenant_id, property_id, wa_contact_id, status, source) values (c.tenant_id, c.property_id, p_wa_contact_id, 'opted_out', 'keyword');
  elsif v_kw in ('START', 'SUBSCRIBE') then
    insert into public.consent_records (tenant_id, property_id, wa_contact_id, status, source) values (c.tenant_id, c.property_id, p_wa_contact_id, 'opted_in', 'keyword');
  end if;

  update public.message_events set processed_at = now() where id = v_ev;
  return v_conv;
end $$;

create function public.ingest_whatsapp_status(p_phone_number_id text, p_event_key text, p_wa_message_id text, p_status text, p_error text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.whatsapp_connections; v_ev uuid;
begin
  select * into c from public.whatsapp_connections where phone_number_id = p_phone_number_id and status = 'active';
  if not found then return; end if;
  insert into public.message_events (tenant_id, property_id, connection_id, event_key, payload)
  values (c.tenant_id, c.property_id, c.id, p_event_key,
          jsonb_build_object('wa_message_id', p_wa_message_id, 'status', p_status, 'error', p_error))
  on conflict (connection_id, event_key) do nothing returning id into v_ev;
  if v_ev is null then return; end if;
  -- If the status races ahead of the worker recording the wamid, it stays unprocessed and is replayed on completion.
  if private.apply_wa_status(c.property_id, p_wa_message_id, p_status, p_error) > 0 then
    update public.message_events set processed_at = now() where id = v_ev;
  end if;
end $$;

create function public.claim_outbound_messages(p_limit int default 10)
returns table (message_id uuid, phone_number_id text, credentials_ref text, wa_contact_id text,
               msg_type text, msg_body text, template_name text, template_language text, attempt int)
language sql security definer set search_path = '' as $$
  with picked as (
    select m.id from public.messages m
    where m.direction = 'out'
      and ((m.status = 'queued' and m.next_attempt_at <= now()) or (m.status = 'sending' and m.locked_at < now() - interval '5 minutes'))
    order by m.created_at limit p_limit for update skip locked
  ), upd as (
    update public.messages m set status = 'sending', locked_at = now(), attempts = m.attempts + 1
    from picked where m.id = picked.id returning m.*
  )
  select u.id, wc.phone_number_id, wc.credentials_ref, cv.wa_contact_id, u.type, u.body, t.name, t.language, u.attempts
  from upd u
  join public.conversations cv on cv.id = u.conversation_id
  join public.whatsapp_connections wc on wc.id = cv.connection_id
  left join public.message_templates t on t.id = u.template_id
$$;

create function public.complete_outbound_message(p_id uuid, p_wa_message_id text, p_ok boolean, p_error text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare m public.messages; ev record;
begin
  update public.messages set
    status = case when p_ok then 'sent' when attempts >= 5 then 'failed' else 'queued' end,     -- 'failed' = dead letter, visible in the inbox
    wa_message_id = coalesce(p_wa_message_id, wa_message_id),
    error = case when p_ok then null else p_error end,
    next_attempt_at = case when not p_ok and attempts < 5 then now() + make_interval(mins => power(2, attempts)::int) else next_attempt_at end,
    locked_at = null
  where id = p_id and status = 'sending' returning * into m;
  if m.id is null or not p_ok or p_wa_message_id is null then return; end if;

  for ev in select id, payload from public.message_events
            where property_id = m.property_id and processed_at is null and payload ->> 'wa_message_id' = p_wa_message_id
            order by received_at loop
    perform private.apply_wa_status(m.property_id, p_wa_message_id, ev.payload ->> 'status', ev.payload ->> 'error');
    update public.message_events set processed_at = now() where id = ev.id;
  end loop;
end $$;

revoke all on function public.ingest_whatsapp_inbound(text, text, text, text, text, text, text, jsonb, timestamptz),
  public.ingest_whatsapp_status(text, text, text, text, text), public.claim_outbound_messages(int),
  public.complete_outbound_message(uuid, text, boolean, text) from public, anon, authenticated;
grant execute on function public.ingest_whatsapp_inbound(text, text, text, text, text, text, text, jsonb, timestamptz),
  public.ingest_whatsapp_status(text, text, text, text, text), public.claim_outbound_messages(int),
  public.complete_outbound_message(uuid, text, boolean, text) to service_role;

-- ---------- staff actions ----------
create function public.connect_whatsapp(p_property uuid, p_phone_number_id text, p_waba_id text, p_display_phone text, p_credentials_ref text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_tenant uuid; v_id uuid;
begin
  select tenant_id into v_tenant from public.properties where id = p_property;
  if v_tenant is null or not private.has_permission(p_property, 'staff.manage') then raise exception 'not permitted' using errcode = '42501'; end if;
  insert into public.whatsapp_connections (tenant_id, property_id, phone_number_id, waba_id, display_phone, credentials_ref)
  values (v_tenant, p_property, p_phone_number_id, p_waba_id, p_display_phone, p_credentials_ref)
  on conflict (property_id) do update set phone_number_id = excluded.phone_number_id, waba_id = excluded.waba_id,
    display_phone = excluded.display_phone, credentials_ref = excluded.credentials_ref, status = 'active'
  returning id into v_id;
  return v_id;
end $$;

create function public.send_whatsapp_message(p_conversation uuid, p_body text default null, p_template uuid default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c public.conversations; t public.message_templates; v_id uuid;
begin
  select * into c from public.conversations where id = p_conversation;
  if not found or not private.has_permission(c.property_id, 'whatsapp.use') then raise exception 'not permitted' using errcode = '42501'; end if;
  if private.is_opted_out(c.property_id, c.wa_contact_id) then raise exception 'contact has opted out' using errcode = '22023'; end if;

  if p_template is not null then
    select * into t from public.message_templates where id = p_template and property_id = c.property_id and status = 'approved';
    if not found then raise exception 'template is not approved for this property' using errcode = '22023'; end if;
  else
    if coalesce(trim(p_body), '') = '' then raise exception 'message body required' using errcode = '22023'; end if;
    if c.last_inbound_at is null or c.last_inbound_at < now() - interval '24 hours' then
      raise exception 'outside the 24-hour window: use an approved template' using errcode = '22023';
    end if;
  end if;

  insert into public.messages (tenant_id, property_id, conversation_id, direction, type, body, template_id, status, sent_by)
  values (c.tenant_id, c.property_id, c.id, 'out', case when t.id is null then 'text' else 'template' end,
          coalesce(t.body, p_body), t.id, 'queued', auth.uid()) returning id into v_id;
  update public.conversations set last_message_at = now() where id = c.id;
  return v_id;
end $$;

create function private.lock_conversation(p_id uuid, p_perm text) returns public.conversations
language plpgsql security definer set search_path = '' as $$
declare c public.conversations;
begin
  select * into c from public.conversations where id = p_id for update;
  if not found or not private.has_permission(c.property_id, p_perm) then raise exception 'not permitted' using errcode = '42501'; end if;
  return c;
end $$;
revoke all on function private.lock_conversation(uuid, text) from public, anon;

create function public.claim_conversation(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.lock_conversation(p_id, 'whatsapp.use');
  update public.conversations set assigned_to = auth.uid() where id = p_id;   -- FK: must be a property member
end $$;

create function public.assign_conversation(p_id uuid, p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.lock_conversation(p_id, 'tasks.assign');
  update public.conversations set assigned_to = p_user where id = p_id;
end $$;

create function public.set_conversation_handoff(p_id uuid, p_human boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.lock_conversation(p_id, 'whatsapp.use');
  update public.conversations set human_handoff = p_human where id = p_id;
end $$;

create function public.close_conversation(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.lock_conversation(p_id, 'whatsapp.use');
  update public.conversations set status = 'closed' where id = p_id;
end $$;

revoke execute on function public.connect_whatsapp(uuid, text, text, text, text), public.send_whatsapp_message(uuid, text, uuid),
  public.claim_conversation(uuid), public.assign_conversation(uuid, uuid), public.set_conversation_handoff(uuid, boolean),
  public.close_conversation(uuid) from public, anon;
grant execute on function public.connect_whatsapp(uuid, text, text, text, text), public.send_whatsapp_message(uuid, text, uuid),
  public.claim_conversation(uuid), public.assign_conversation(uuid, uuid), public.set_conversation_handoff(uuid, boolean),
  public.close_conversation(uuid) to authenticated;
