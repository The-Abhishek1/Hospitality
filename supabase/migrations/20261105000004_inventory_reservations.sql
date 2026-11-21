-- Milestone 3 (part 1): accommodation inventory + transactional reservations.
-- Anti-overselling guarantee: ONE exclusion constraint on unit_holds. A unit can never have two
-- active holds with overlapping dates, regardless of how the row got there (direct booking, OTA, block).
-- Deviation from spec inventory: reservation_units and inventory_blocks are unified as unit_holds
-- (kind = reservation | block) so a single constraint covers both.

create extension if not exists btree_gist with schema extensions;

insert into public.permissions (key, description) values ('inventory.manage', 'Manage accommodation types, units, rate plans, blocks');
insert into public.role_permissions (role_id, permission_key)
  select id, 'inventory.manage' from public.roles where key = 'manager' and tenant_id is null;

create function private.has_tenant_permission(t uuid, perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_tenant_admin(t) or exists (
    select 1 from public.user_roles ur
    join public.role_permissions rp on rp.role_id = ur.role_id
    join public.properties p on p.id = ur.property_id
    where p.tenant_id = t and ur.user_id = (select auth.uid()) and rp.permission_key = perm)
$$;
revoke all on function private.has_tenant_permission(uuid, text) from public, anon;
grant execute on function private.has_tenant_permission(uuid, text) to authenticated;

-- ---------- tables ----------
create table public.accommodation_types (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  name text not null,
  kind text not null default 'room' check (kind in ('room', 'bed', 'suite', 'entire_property')),
  max_occupancy int not null check (max_occupancy > 0),
  base_rate numeric(12,2) not null check (base_rate >= 0),
  created_at timestamptz not null default now(),
  unique (id, property_id),
  unique (property_id, name),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade
);

create table public.accommodation_units (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  type_id uuid not null,
  name text not null,
  active boolean not null default true,
  housekeeping_status text not null default 'clean' check (housekeeping_status in ('clean', 'dirty', 'in_progress')),
  unique (id, property_id),
  unique (property_id, name),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade,
  foreign key (type_id, property_id) references public.accommodation_types (id, property_id)
);
create index on public.accommodation_units (property_id, type_id);

create table public.rate_plans (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  code text not null,
  name text not null,
  adjustment_percent numeric(6,2) not null default 0,   -- vs type base_rate; real pricing/restrictions come later
  unique (id, property_id),
  unique (property_id, code),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade
);

create table public.guests (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  full_name text not null check (length(trim(full_name)) > 0),
  phone text,
  email text,
  created_at timestamptz not null default now(),
  unique (id, tenant_id)
);
create index on public.guests (tenant_id);

create table public.reservations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  guest_id uuid not null,
  status text not null default 'confirmed' check (status in ('confirmed', 'checked_in', 'checked_out', 'cancelled', 'no_show')),
  source text not null default 'direct' check (source in ('direct', 'walk_in', 'ota')),
  channel_ref text,                                  -- external id, used for idempotency
  check_in date not null,                            -- property-local dates; events use UTC timestamps
  check_out date not null,
  adults int not null default 1 check (adults >= 1),
  children int not null default 0 check (children >= 0),
  rate_plan_id uuid,
  total_amount numeric(12,2) not null check (total_amount >= 0),
  currency char(3) not null,
  checked_in_at timestamptz,
  checked_out_at timestamptz,
  cancelled_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  check (check_out > check_in),
  unique (id, property_id),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade,
  foreign key (guest_id, tenant_id) references public.guests (id, tenant_id),
  foreign key (rate_plan_id, property_id) references public.rate_plans (id, property_id)
);
create unique index reservations_channel_ref_uq on public.reservations (property_id, source, channel_ref) where channel_ref is not null;
create index on public.reservations (property_id, check_in);

create table public.unit_holds (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  unit_id uuid not null,
  during daterange not null check (not isempty(during)),   -- [check_in, check_out): same-day turnover allowed
  kind text not null check (kind in ('reservation', 'block')),
  reservation_id uuid,
  reason text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check ((kind = 'reservation') = (reservation_id is not null)),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade,
  foreign key (unit_id, property_id) references public.accommodation_units (id, property_id) on delete cascade,
  foreign key (reservation_id, property_id) references public.reservations (id, property_id) on delete cascade,
  exclude using gist (unit_id with =, during with &&) where (active)
);
create index on public.unit_holds (reservation_id);

create table public.reservation_events (       -- append-only audit trail
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  reservation_id uuid not null,
  event_type text not null,
  actor_id uuid,
  details jsonb not null default '{}',
  created_at timestamptz not null default now(),
  foreign key (reservation_id, property_id) references public.reservations (id, property_id) on delete cascade
);
create index on public.reservation_events (reservation_id, created_at);

-- ---------- RLS (reads by permission; reservation/hold/event writes ONLY via the functions below) ----------
alter table public.accommodation_types enable row level security;
alter table public.accommodation_units enable row level security;
alter table public.rate_plans enable row level security;
alter table public.guests enable row level security;
alter table public.reservations enable row level security;
alter table public.unit_holds enable row level security;
alter table public.reservation_events enable row level security;

create policy types_select on public.accommodation_types for select to authenticated using (private.has_property_access(property_id));
create policy types_write on public.accommodation_types for all to authenticated
  using (private.has_permission(property_id, 'inventory.manage')) with check (private.has_permission(property_id, 'inventory.manage'));
create policy units_select on public.accommodation_units for select to authenticated using (private.has_property_access(property_id));
create policy units_write on public.accommodation_units for all to authenticated
  using (private.has_permission(property_id, 'inventory.manage')) with check (private.has_permission(property_id, 'inventory.manage'));
create policy rate_plans_select on public.rate_plans for select to authenticated using (private.has_property_access(property_id));
create policy rate_plans_write on public.rate_plans for all to authenticated
  using (private.has_permission(property_id, 'inventory.manage')) with check (private.has_permission(property_id, 'inventory.manage'));

create policy guests_select on public.guests for select to authenticated using (private.has_tenant_permission(tenant_id, 'reservations.read'));
create policy guests_write on public.guests for all to authenticated
  using (private.has_tenant_permission(tenant_id, 'reservations.write')) with check (private.has_tenant_permission(tenant_id, 'reservations.write'));

create policy reservations_select on public.reservations for select to authenticated using (private.has_permission(property_id, 'reservations.read'));
create policy holds_select on public.unit_holds for select to authenticated using (private.has_property_access(property_id));
create policy events_select on public.reservation_events for select to authenticated using (private.has_permission(property_id, 'reservations.read'));

-- ---------- functions ----------
create function private.lock_reservation(p_id uuid, p_perm text) returns public.reservations
language plpgsql security definer set search_path = '' as $$
declare r public.reservations;
begin
  select * into r from public.reservations where id = p_id for update;
  if not found or not private.has_permission(r.property_id, p_perm) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return r;
end $$;
revoke all on function private.lock_reservation(uuid, text) from public, anon;

create function public.create_reservation(
  p_property uuid, p_guest uuid, p_type uuid, p_check_in date, p_check_out date,
  p_adults int default 1, p_children int default 0, p_rate_plan uuid default null,
  p_source text default 'direct', p_channel_ref text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_tenant uuid; v_cur char(3); v_type public.accommodation_types; v_adj numeric := 0;
  v_id uuid; v_unit uuid; v_ok boolean := false; v_total numeric;
begin
  select tenant_id, currency into v_tenant, v_cur from public.properties where id = p_property;
  if v_tenant is null or not private.has_permission(p_property, 'reservations.write') then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if p_check_out <= p_check_in then raise exception 'check_out must be after check_in' using errcode = '22023'; end if;

  select * into v_type from public.accommodation_types where id = p_type and property_id = p_property;
  if not found then raise exception 'unknown accommodation type' using errcode = '22023'; end if;
  if p_adults < 1 or p_adults + p_children > v_type.max_occupancy then
    raise exception 'occupancy exceeds type capacity' using errcode = '22023';
  end if;
  if not exists (select 1 from public.guests where id = p_guest and tenant_id = v_tenant) then
    raise exception 'guest not found in this tenant' using errcode = '23503';
  end if;
  if p_rate_plan is not null then
    select adjustment_percent into v_adj from public.rate_plans where id = p_rate_plan and property_id = p_property;
    if not found then raise exception 'unknown rate plan' using errcode = '22023'; end if;
  end if;

  -- Idempotency for OTA/webhook retries.
  if p_channel_ref is not null then
    select id into v_id from public.reservations
      where property_id = p_property and source = p_source and channel_ref = p_channel_ref;
    if found then return v_id; end if;
  end if;

  v_total := round(v_type.base_rate * (p_check_out - p_check_in) * (1 + v_adj / 100), 2);
  insert into public.reservations (tenant_id, property_id, guest_id, source, channel_ref, check_in, check_out,
                                   adults, children, rate_plan_id, total_amount, currency, created_by)
  values (v_tenant, p_property, p_guest, p_source, p_channel_ref, p_check_in, p_check_out,
          p_adults, p_children, p_rate_plan, v_total, v_cur, auth.uid())
  returning id into v_id;

  -- Try candidate units in order; the exclusion constraint is the arbiter if another transaction wins a unit.
  for v_unit in
    select u.id from public.accommodation_units u
    where u.property_id = p_property and u.type_id = p_type and u.active
      and not exists (select 1 from public.unit_holds h
                      where h.unit_id = u.id and h.active and h.during && daterange(p_check_in, p_check_out, '[)'))
    order by u.name
  loop
    begin
      insert into public.unit_holds (tenant_id, property_id, unit_id, during, kind, reservation_id)
      values (v_tenant, p_property, v_unit, daterange(p_check_in, p_check_out, '[)'), 'reservation', v_id);
      v_ok := true;
      exit;
    exception when exclusion_violation then
      null; -- lost the race for this unit; try the next one
    end;
  end loop;

  if not v_ok then raise exception 'no availability for requested dates' using errcode = 'P0002'; end if;

  insert into public.reservation_events (tenant_id, property_id, reservation_id, event_type, actor_id, details)
  values (v_tenant, p_property, v_id, 'created', auth.uid(), jsonb_build_object('unit_id', v_unit, 'source', p_source));
  return v_id;
end $$;

create function public.cancel_reservation(p_id uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.reservations;
begin
  r := private.lock_reservation(p_id, 'reservations.write');
  if r.status <> 'confirmed' then raise exception 'cannot cancel from status %', r.status using errcode = '22023'; end if;
  update public.reservations set status = 'cancelled', cancelled_at = now() where id = p_id;
  update public.unit_holds set active = false where reservation_id = p_id;
  insert into public.reservation_events (tenant_id, property_id, reservation_id, event_type, actor_id, details)
  values (r.tenant_id, r.property_id, p_id, 'cancelled', auth.uid(), jsonb_build_object('reason', p_reason));
end $$;

create function public.check_in_reservation(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.reservations;
begin
  r := private.lock_reservation(p_id, 'frontdesk.manage');
  if r.status <> 'confirmed' then raise exception 'cannot check in from status %', r.status using errcode = '22023'; end if;
  update public.reservations set status = 'checked_in', checked_in_at = now() where id = p_id;
  insert into public.reservation_events (tenant_id, property_id, reservation_id, event_type, actor_id)
  values (r.tenant_id, r.property_id, p_id, 'checked_in', auth.uid());
end $$;

-- Marks units dirty. Folio finalisation and the housekeeping task are added with milestones 4 and 7.
create function public.check_out_reservation(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.reservations;
begin
  r := private.lock_reservation(p_id, 'frontdesk.manage');
  if r.status <> 'checked_in' then raise exception 'cannot check out from status %', r.status using errcode = '22023'; end if;
  update public.reservations set status = 'checked_out', checked_out_at = now() where id = p_id;
  update public.accommodation_units set housekeeping_status = 'dirty'
    where id in (select unit_id from public.unit_holds where reservation_id = p_id and active);
  insert into public.reservation_events (tenant_id, property_id, reservation_id, event_type, actor_id)
  values (r.tenant_id, r.property_id, p_id, 'checked_out', auth.uid());
end $$;

create function public.create_inventory_block(p_unit uuid, p_from date, p_to date, p_reason text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare u public.accommodation_units; v_id uuid;
begin
  select * into u from public.accommodation_units where id = p_unit;
  if not found or not private.has_permission(u.property_id, 'inventory.manage') then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if p_to <= p_from then raise exception 'end must be after start' using errcode = '22023'; end if;
  insert into public.unit_holds (tenant_id, property_id, unit_id, during, kind, reason)
  values (u.tenant_id, u.property_id, u.id, daterange(p_from, p_to, '[)'), 'block', p_reason)
  returning id into v_id;   -- overlapping an existing hold raises 23P01
  return v_id;
end $$;

-- Invoker rights: RLS decides what the caller may see.
create function public.availability(p_property uuid, p_from date, p_to date)
returns table (type_id uuid, type_name text, available bigint)
language sql stable security invoker set search_path = '' as $$
  select t.id, t.name,
    count(u.id) filter (where not exists (
      select 1 from public.unit_holds h
      where h.unit_id = u.id and h.active and h.during && daterange(p_from, p_to, '[)')))
  from public.accommodation_types t
  left join public.accommodation_units u on u.type_id = t.id and u.active
  where t.property_id = p_property
  group by t.id, t.name order by t.name
$$;

revoke execute on function
  public.create_reservation(uuid, uuid, uuid, date, date, int, int, uuid, text, text),
  public.cancel_reservation(uuid, text), public.check_in_reservation(uuid), public.check_out_reservation(uuid),
  public.create_inventory_block(uuid, date, date, text), public.availability(uuid, date, date)
  from public, anon;
grant execute on function
  public.create_reservation(uuid, uuid, uuid, date, date, int, int, uuid, text, text),
  public.cancel_reservation(uuid, text), public.check_in_reservation(uuid), public.check_out_reservation(uuid),
  public.create_inventory_block(uuid, date, date, text), public.availability(uuid, date, date)
  to authenticated;
