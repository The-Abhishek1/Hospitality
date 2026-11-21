-- Milestone 10: channel manager core + MOCK provider only. No real OTA is supported by this migration:
-- real adapters need partner access, certification and end-to-end tests first.
-- Outbound: unit_holds changes -> coalesced availability sync_jobs -> worker pushes via a provider adapter (retry/backoff/dead).
-- Inbound: adapters normalise provider events -> channel_events (deduped) -> processed transactionally, idempotently.
-- Overbooking is impossible: allocation still goes through the unit_holds exclusion constraint; a conflicting OTA
-- booking becomes a visible failed event for a human to resolve.

-- ---------- shared allocation core (extracted so staff, OTA and portal paths use one implementation) ----------
create function private.allocate_unit(p_property uuid, p_tenant uuid, p_type uuid, p_in date, p_out date, p_reservation uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_unit uuid;
begin
  for v_unit in
    select u.id from public.accommodation_units u
    where u.property_id = p_property and u.type_id = p_type and u.active
      and not exists (select 1 from public.unit_holds h where h.unit_id = u.id and h.active and h.during && daterange(p_in, p_out, '[)'))
    order by u.name
  loop
    begin
      insert into public.unit_holds (tenant_id, property_id, unit_id, during, kind, reservation_id)
      values (p_tenant, p_property, v_unit, daterange(p_in, p_out, '[)'), 'reservation', p_reservation);
      return v_unit;
    exception when exclusion_violation then null;     -- lost the race for this unit; try the next
    end;
  end loop;
  return null;
end $$;
revoke all on function private.allocate_unit(uuid, uuid, uuid, date, date, uuid) from public, anon, authenticated;

create function private.create_reservation_core(
  p_property uuid, p_guest uuid, p_type uuid, p_check_in date, p_check_out date, p_adults int, p_children int,
  p_rate_plan uuid, p_source text, p_channel_ref text, p_actor uuid, p_total numeric default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_tenant uuid; v_cur char(3); v_type public.accommodation_types; v_adj numeric := 0; v_id uuid; v_unit uuid; v_total numeric;
begin
  select tenant_id, currency into v_tenant, v_cur from public.properties where id = p_property;
  if v_tenant is null then raise exception 'unknown property' using errcode = '22023'; end if;
  if p_check_out <= p_check_in then raise exception 'check_out must be after check_in' using errcode = '22023'; end if;

  select * into v_type from public.accommodation_types where id = p_type and property_id = p_property;
  if not found then raise exception 'unknown accommodation type' using errcode = '22023'; end if;
  if p_adults < 1 or p_adults + p_children > v_type.max_occupancy then raise exception 'occupancy exceeds type capacity' using errcode = '22023'; end if;
  if not exists (select 1 from public.guests where id = p_guest and tenant_id = v_tenant) then raise exception 'guest not found in this tenant' using errcode = '23503'; end if;
  if p_rate_plan is not null then
    select adjustment_percent into v_adj from public.rate_plans where id = p_rate_plan and property_id = p_property;
    if not found then raise exception 'unknown rate plan' using errcode = '22023'; end if;
  end if;

  if p_channel_ref is not null then      -- idempotency for OTA/webhook retries
    select id into v_id from public.reservations where property_id = p_property and source = p_source and channel_ref = p_channel_ref;
    if found then return v_id; end if;
  end if;

  v_total := coalesce(p_total, round(v_type.base_rate * (p_check_out - p_check_in) * (1 + v_adj / 100), 2));
  insert into public.reservations (tenant_id, property_id, guest_id, source, channel_ref, check_in, check_out,
                                   adults, children, rate_plan_id, total_amount, currency, created_by)
  values (v_tenant, p_property, p_guest, p_source, p_channel_ref, p_check_in, p_check_out,
          p_adults, p_children, p_rate_plan, v_total, v_cur, p_actor) returning id into v_id;

  v_unit := private.allocate_unit(p_property, v_tenant, p_type, p_check_in, p_check_out, v_id);
  if v_unit is null then raise exception 'no availability for requested dates' using errcode = 'P0002'; end if;

  insert into public.reservation_events (tenant_id, property_id, reservation_id, event_type, actor_id, details)
  values (v_tenant, p_property, v_id, 'created', p_actor, jsonb_build_object('unit_id', v_unit, 'source', p_source));
  return v_id;
end $$;
revoke all on function private.create_reservation_core(uuid, uuid, uuid, date, date, int, int, uuid, text, text, uuid, numeric) from public, anon, authenticated;

create or replace function public.create_reservation(
  p_property uuid, p_guest uuid, p_type uuid, p_check_in date, p_check_out date,
  p_adults int default 1, p_children int default 0, p_rate_plan uuid default null,
  p_source text default 'direct', p_channel_ref text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  if not private.has_permission(p_property, 'reservations.write') then raise exception 'not permitted' using errcode = '42501'; end if;
  return private.create_reservation_core(p_property, p_guest, p_type, p_check_in, p_check_out, p_adults, p_children, p_rate_plan, p_source, p_channel_ref, auth.uid());
end $$;

-- ---------- tables ----------
create table public.channel_connections (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null,
  provider text not null check (provider in ('mock')),          -- real providers are added only after certification
  credentials_ref text,
  status text not null default 'active' check (status in ('active', 'paused')),
  last_sync_at timestamptz, created_at timestamptz not null default now(),
  unique (id, property_id), unique (property_id, provider),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade
);
create table public.channel_unit_mappings (          -- sellable accommodation TYPE <-> provider room id
  connection_id uuid not null references public.channel_connections(id) on delete cascade,
  tenant_id uuid not null, property_id uuid not null, type_id uuid not null,
  external_room_id text not null,
  primary key (connection_id, type_id), unique (connection_id, external_room_id),
  foreign key (type_id, property_id) references public.accommodation_types (id, property_id) on delete cascade
);
create table public.channel_rate_mappings (          -- stored now; rate/restriction push is not implemented yet
  connection_id uuid not null references public.channel_connections(id) on delete cascade,
  tenant_id uuid not null, property_id uuid not null, rate_plan_id uuid not null,
  external_rate_id text not null,
  primary key (connection_id, rate_plan_id), unique (connection_id, external_rate_id),
  foreign key (rate_plan_id, property_id) references public.rate_plans (id, property_id) on delete cascade
);
create table public.channel_events (                 -- inbound, normalised, deduped by provider event id
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null,
  connection_id uuid not null references public.channel_connections(id) on delete cascade,
  external_event_id text not null, payload jsonb not null,
  status text not null default 'received' check (status in ('received', 'processed', 'failed', 'dead')),
  error text, attempts int not null default 0,
  next_attempt_at timestamptz not null default now(),
  received_at timestamptz not null default clock_timestamp(), processed_at timestamptz,
  unique (connection_id, external_event_id)
);
create index on public.channel_events (next_attempt_at) where status in ('received', 'failed');
create table public.sync_jobs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null,
  connection_id uuid not null references public.channel_connections(id) on delete cascade,
  job_type text not null default 'availability' check (job_type in ('availability')),
  type_id uuid not null references public.accommodation_types(id) on delete cascade,
  date_from date not null, date_to date not null check (date_to > date_from),
  status text not null default 'queued' check (status in ('queued', 'running', 'succeeded', 'dead', 'superseded')),
  attempts int not null default 0, error text,
  next_attempt_at timestamptz not null default now(), locked_at timestamptz,
  created_at timestamptz not null default now(), finished_at timestamptz
);
create unique index sync_jobs_one_queued on public.sync_jobs (connection_id, type_id, job_type) where status = 'queued';
create index on public.sync_jobs (next_attempt_at) where status in ('queued', 'running');
create table public.sync_attempts (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.sync_jobs(id) on delete cascade,
  attempt int not null, ok boolean not null, error text, created_at timestamptz not null default clock_timestamp()
);
create table public.mock_ota_availability (          -- what the mock "OTA" currently believes
  connection_id uuid not null references public.channel_connections(id) on delete cascade,
  external_room_id text not null, day date not null, available int not null, updated_at timestamptz not null default now(),
  primary key (connection_id, external_room_id, day)
);
create table public.mock_ota_outbox (                -- events the mock "OTA" wants to send us
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references public.channel_connections(id) on delete cascade,
  payload jsonb not null, created_at timestamptz not null default clock_timestamp()
);

alter table public.channel_connections enable row level security;
alter table public.channel_unit_mappings enable row level security;
alter table public.channel_rate_mappings enable row level security;
alter table public.channel_events enable row level security;
alter table public.sync_jobs enable row level security;
alter table public.sync_attempts enable row level security;
alter table public.mock_ota_availability enable row level security;   -- no policies: service_role only
alter table public.mock_ota_outbox enable row level security;
create policy cc_select on public.channel_connections for select to authenticated using (private.has_permission(property_id, 'staff.manage'));
create policy cum_select on public.channel_unit_mappings for select to authenticated using (private.has_permission(property_id, 'staff.manage'));
create policy crm_select on public.channel_rate_mappings for select to authenticated using (private.has_permission(property_id, 'staff.manage'));
create policy ce_select on public.channel_events for select to authenticated using (private.has_permission(property_id, 'staff.manage'));
create policy sj_select on public.sync_jobs for select to authenticated using (private.has_permission(property_id, 'staff.manage'));
create policy sa_select on public.sync_attempts for select to authenticated
  using (exists (select 1 from public.sync_jobs j where j.id = job_id));

-- ---------- outbound: coalesced availability jobs ----------
create function private.enqueue_sync(p_conn uuid, p_type uuid, p_from date, p_to date) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.channel_connections;
begin
  select * into c from public.channel_connections where id = p_conn;
  insert into public.sync_jobs (tenant_id, property_id, connection_id, type_id, date_from, date_to)
  values (c.tenant_id, c.property_id, p_conn, p_type, p_from, p_to)
  on conflict (connection_id, type_id, job_type) where status = 'queued'
  do update set date_from = least(public.sync_jobs.date_from, excluded.date_from),
                date_to = greatest(public.sync_jobs.date_to, excluded.date_to),
                next_attempt_at = least(public.sync_jobs.next_attempt_at, now());
end $$;
revoke all on function private.enqueue_sync(uuid, uuid, date, date) from public, anon, authenticated;

create function private.on_hold_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_type uuid; r record;
begin
  select type_id into v_type from public.accommodation_units where id = new.unit_id;
  for r in select c.id from public.channel_connections c
           join public.channel_unit_mappings m on m.connection_id = c.id and m.type_id = v_type
           where c.property_id = new.property_id and c.status = 'active'
  loop
    perform private.enqueue_sync(r.id, v_type, lower(new.during), upper(new.during));
    if tg_op = 'UPDATE' and old.during is distinct from new.during then
      perform private.enqueue_sync(r.id, v_type, lower(old.during), upper(old.during));
    end if;
  end loop;
  return new;
end $$;
create trigger unit_holds_channel_sync after insert or update of active, during on public.unit_holds
  for each row execute function private.on_hold_change();

-- Availability per mapped room per night: active units of the type minus units held that night.
create function public.channel_availability_range(p_connection uuid, p_from date, p_to date)
returns table (external_room_id text, type_id uuid, day date, available int)
language sql stable security definer set search_path = '' as $$
  select m.external_room_id, m.type_id, d::date,
    (select count(*)::int from public.accommodation_units u
      where u.type_id = m.type_id and u.active
        and not exists (select 1 from public.unit_holds h where h.unit_id = u.id and h.active and h.during @> d::date))
  from public.channel_unit_mappings m
  cross join generate_series(p_from, p_to - 1, interval '1 day') d
  where m.connection_id = p_connection
$$;

create function public.claim_sync_jobs(p_limit int default 10)
returns table (job_id uuid, connection_id uuid, provider text, credentials_ref text, type_id uuid, external_room_id text, date_from date, date_to date, attempt int)
language sql security definer set search_path = '' as $$
  with picked as (
    select j.id from public.sync_jobs j
    where (j.status = 'queued' and j.next_attempt_at <= now()) or (j.status = 'running' and j.locked_at < now() - interval '5 minutes')
    order by j.created_at limit p_limit for update skip locked
  ), upd as (
    update public.sync_jobs j set status = 'running', locked_at = now(), attempts = j.attempts + 1
    from picked where j.id = picked.id returning j.*
  )
  select u.id, u.connection_id, c.provider, c.credentials_ref, u.type_id, m.external_room_id, u.date_from, u.date_to, u.attempts
  from upd u
  join public.channel_connections c on c.id = u.connection_id
  join public.channel_unit_mappings m on m.connection_id = u.connection_id and m.type_id = u.type_id
$$;

create function public.complete_sync_job(p_id uuid, p_ok boolean, p_error text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare j public.sync_jobs;
begin
  select * into j from public.sync_jobs where id = p_id and status = 'running' for update;
  if not found then return; end if;
  insert into public.sync_attempts (job_id, attempt, ok, error) values (p_id, j.attempts, p_ok, p_error);

  if p_ok then
    update public.sync_jobs set status = 'succeeded', error = null, finished_at = now(), locked_at = null where id = p_id;
    update public.channel_connections set last_sync_at = now() where id = j.connection_id;
  elsif j.attempts >= 5 then
    update public.sync_jobs set status = 'dead', error = p_error, finished_at = now(), locked_at = null where id = p_id;   -- visible dead letter
  elsif exists (select 1 from public.sync_jobs where connection_id = j.connection_id and type_id = j.type_id and job_type = j.job_type and status = 'queued') then
    -- a newer job already covers this key: fold our range into it instead of requeueing a duplicate
    perform private.enqueue_sync(j.connection_id, j.type_id, j.date_from, j.date_to);
    update public.sync_jobs set status = 'superseded', error = p_error, finished_at = now(), locked_at = null where id = p_id;
  else
    update public.sync_jobs set status = 'queued', error = p_error, locked_at = null,
      next_attempt_at = now() + make_interval(mins => power(2, j.attempts)::int) where id = p_id;
  end if;
end $$;

-- ---------- inbound ----------
create function public.ingest_channel_event(p_connection uuid, p_external_id text, p_payload jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c public.channel_connections; v_id uuid;
begin
  select * into c from public.channel_connections where id = p_connection and status = 'active';
  if not found then return null; end if;
  insert into public.channel_events (tenant_id, property_id, connection_id, external_event_id, payload)
  values (c.tenant_id, c.property_id, c.id, p_external_id, p_payload)
  on conflict (connection_id, external_event_id) do nothing returning id into v_id;
  return v_id;                                     -- null = duplicate delivery
end $$;

-- Normalised payload: {type: reservation.created|modified|cancelled, external_reservation_id, external_room_id,
--   check_in, check_out, adults, children, guest_name, guest_phone, guest_email, total_amount}
create function private.process_channel_event(p_event uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  e public.channel_events; c public.channel_connections; pl jsonb; v_ref text; v_type uuid; v_guest uuid; r public.reservations; v_unit uuid;
begin
  select * into e from public.channel_events where id = p_event;
  select * into c from public.channel_connections where id = e.connection_id;
  pl := e.payload;
  v_ref := c.provider || ':' || (pl ->> 'external_reservation_id');
  begin
    if pl ->> 'type' in ('reservation.created', 'reservation.modified') then
      select m.type_id into v_type from public.channel_unit_mappings m where m.connection_id = c.id and m.external_room_id = pl ->> 'external_room_id';
      if v_type is null then raise exception 'unmapped room %', pl ->> 'external_room_id' using errcode = '22023'; end if;
    end if;

    if pl ->> 'type' = 'reservation.created' then
      if not exists (select 1 from public.reservations where property_id = c.property_id and source = 'ota' and channel_ref = v_ref) then
        insert into public.guests (tenant_id, full_name, phone, email)
        values (c.tenant_id, coalesce(nullif(trim(pl ->> 'guest_name'), ''), 'OTA guest'), pl ->> 'guest_phone', pl ->> 'guest_email') returning id into v_guest;
        perform private.create_reservation_core(c.property_id, v_guest, v_type, (pl ->> 'check_in')::date, (pl ->> 'check_out')::date,
          coalesce((pl ->> 'adults')::int, 1), coalesce((pl ->> 'children')::int, 0), null, 'ota', v_ref, null, (pl ->> 'total_amount')::numeric);
      end if;

    elsif pl ->> 'type' = 'reservation.modified' then
      select * into r from public.reservations where property_id = c.property_id and source = 'ota' and channel_ref = v_ref for update;
      if not found then raise exception 'unknown reservation %', v_ref using errcode = '22023'; end if;   -- may arrive before its create; retried
      if r.status <> 'confirmed' then raise exception 'cannot modify a % reservation', r.status using errcode = '22023'; end if;
      update public.unit_holds set active = false where reservation_id = r.id and active;
      v_unit := private.allocate_unit(c.property_id, c.tenant_id, v_type, (pl ->> 'check_in')::date, (pl ->> 'check_out')::date, r.id);
      if v_unit is null then raise exception 'no availability for the modified dates' using errcode = 'P0002'; end if;   -- rolls back; old hold stays
      update public.reservations set check_in = (pl ->> 'check_in')::date, check_out = (pl ->> 'check_out')::date,
        adults = coalesce((pl ->> 'adults')::int, adults), children = coalesce((pl ->> 'children')::int, children),
        total_amount = coalesce((pl ->> 'total_amount')::numeric, total_amount) where id = r.id;
      insert into public.reservation_events (tenant_id, property_id, reservation_id, event_type, details)
      values (c.tenant_id, c.property_id, r.id, 'modified_by_channel', jsonb_build_object('unit_id', v_unit));

    elsif pl ->> 'type' = 'reservation.cancelled' then
      select * into r from public.reservations where property_id = c.property_id and source = 'ota' and channel_ref = v_ref for update;
      if not found then raise exception 'unknown reservation %', v_ref using errcode = '22023'; end if;
      if r.status = 'confirmed' then
        update public.reservations set status = 'cancelled', cancelled_at = now() where id = r.id;
        update public.unit_holds set active = false where reservation_id = r.id;
        insert into public.reservation_events (tenant_id, property_id, reservation_id, event_type) values (c.tenant_id, c.property_id, r.id, 'cancelled_by_channel');
      end if;                                                          -- already cancelled/in-house: nothing to do (idempotent)
    else
      raise exception 'unsupported event type %', pl ->> 'type' using errcode = '22023';
    end if;
    update public.channel_events set status = 'processed', processed_at = now(), error = null where id = p_event;
  exception when others then
    update public.channel_events set
      status = case when attempts + 1 >= 5 then 'dead' else 'failed' end, error = sqlerrm, attempts = attempts + 1,
      next_attempt_at = now() + make_interval(mins => power(2, attempts + 1)::int)
    where id = p_event;
  end;
end $$;
revoke all on function private.process_channel_event(uuid) from public, anon, authenticated;

create function public.process_pending_channel_events(p_limit int default 20) returns int
language plpgsql security definer set search_path = '' as $$
declare v record; n int := 0;
begin
  for v in select id from public.channel_events where status in ('received', 'failed') and next_attempt_at <= now()
           order by received_at, id limit p_limit for update skip locked
  loop
    perform private.process_channel_event(v.id);
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- mock provider (test double for adapters) ----------
create function public.mock_provider_push(p_connection uuid, p_room text, p_day date, p_available int) returns void
language sql security definer set search_path = '' as $$
  insert into public.mock_ota_availability (connection_id, external_room_id, day, available) values (p_connection, p_room, p_day, p_available)
  on conflict (connection_id, external_room_id, day) do update set available = excluded.available, updated_at = now()
$$;
create function public.mock_reconcile(p_connection uuid, p_from date, p_to date)
returns table (external_room_id text, day date, expected int, actual int)
language sql stable security definer set search_path = '' as $$
  select a.external_room_id, a.day, a.available, m.available
  from public.channel_availability_range(p_connection, p_from, p_to) a
  left join public.mock_ota_availability m on m.connection_id = p_connection and m.external_room_id = a.external_room_id and m.day = a.day
  where m.available is distinct from a.available
$$;
create function public.mock_ota_emit(p_connection uuid, p_payload jsonb) returns void
language sql security definer set search_path = '' as $$
  insert into public.mock_ota_outbox (connection_id, payload) values (p_connection, p_payload)
$$;
create function public.mock_ota_poll(p_connection uuid) returns setof jsonb
language sql security definer set search_path = '' as $$
  with d as (delete from public.mock_ota_outbox where connection_id = p_connection returning payload, created_at)
  select payload from d order by created_at
$$;

-- ---------- staff configuration ----------
create function public.connect_channel(p_property uuid, p_provider text, p_credentials_ref text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_tenant uuid; v_id uuid;
begin
  select tenant_id into v_tenant from public.properties where id = p_property;
  if v_tenant is null or not private.has_permission(p_property, 'staff.manage') then raise exception 'not permitted' using errcode = '42501'; end if;
  insert into public.channel_connections (tenant_id, property_id, provider, credentials_ref) values (v_tenant, p_property, p_provider, p_credentials_ref)
  on conflict (property_id, provider) do update set credentials_ref = excluded.credentials_ref, status = 'active' returning id into v_id;
  return v_id;
end $$;

create function public.map_channel_room(p_connection uuid, p_type uuid, p_external_room_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.channel_connections;
begin
  select * into c from public.channel_connections where id = p_connection;
  if not found or not private.has_permission(c.property_id, 'staff.manage') then raise exception 'not permitted' using errcode = '42501'; end if;
  if not exists (select 1 from public.accommodation_types where id = p_type and property_id = c.property_id) then
    raise exception 'accommodation type does not belong to this property' using errcode = '22023';
  end if;
  insert into public.channel_unit_mappings (connection_id, tenant_id, property_id, type_id, external_room_id)
  values (p_connection, c.tenant_id, c.property_id, p_type, p_external_room_id)
  on conflict (connection_id, type_id) do update set external_room_id = excluded.external_room_id;
  perform private.enqueue_sync(p_connection, p_type, current_date, current_date + 365);   -- push the initial picture
end $$;

create function public.request_channel_resync(p_connection uuid, p_days int default 365) returns int
language plpgsql security definer set search_path = '' as $$
declare c public.channel_connections; m record; n int := 0;
begin
  select * into c from public.channel_connections where id = p_connection;
  if not found or not private.has_permission(c.property_id, 'staff.manage') then raise exception 'not permitted' using errcode = '42501'; end if;
  for m in select type_id from public.channel_unit_mappings where connection_id = p_connection loop
    perform private.enqueue_sync(p_connection, m.type_id, current_date, current_date + greatest(1, least(p_days, 730)));
    n := n + 1;
  end loop;
  return n;
end $$;

revoke execute on function
  public.channel_availability_range(uuid, date, date), public.claim_sync_jobs(int), public.complete_sync_job(uuid, boolean, text),
  public.ingest_channel_event(uuid, text, jsonb), public.process_pending_channel_events(int),
  public.mock_provider_push(uuid, text, date, int), public.mock_reconcile(uuid, date, date),
  public.mock_ota_emit(uuid, jsonb), public.mock_ota_poll(uuid),
  public.connect_channel(uuid, text, text), public.map_channel_room(uuid, uuid, text), public.request_channel_resync(uuid, int)
  from public, anon, authenticated;
grant execute on function
  public.channel_availability_range(uuid, date, date), public.claim_sync_jobs(int), public.complete_sync_job(uuid, boolean, text),
  public.ingest_channel_event(uuid, text, jsonb), public.process_pending_channel_events(int),
  public.mock_provider_push(uuid, text, date, int), public.mock_reconcile(uuid, date, date),
  public.mock_ota_emit(uuid, jsonb), public.mock_ota_poll(uuid) to service_role;
grant execute on function public.connect_channel(uuid, text, text), public.map_channel_room(uuid, uuid, text), public.request_channel_resync(uuid, int) to authenticated;
