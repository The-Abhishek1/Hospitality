-- Milestone 7: restaurant/room-service orders, folios, payments, refunds, invoices, night audit.
-- Rules: an order and a payment are separate records; money is numeric; no raw card data is ever stored
-- (payments keep only a method and an opaque reference); all writes go through permission-checked functions.
-- Deferred: cash_sessions, expenses, GST-compliant invoice series (needs counsel), per-night pricing.

insert into public.permissions (key, description) values
  ('billing.manage', 'Post charges, collect payments, issue invoices, run night audit'),
  ('orders.place',   'Place restaurant and room-service orders');
insert into public.role_permissions (role_id, permission_key)
select r.id, m.p from (values
  ('front_desk','billing.manage'), ('front_desk','orders.place'), ('front_desk','orders.read'),
  ('manager','billing.manage'), ('manager','orders.place'), ('accountant','billing.manage')
) m(k, p) join public.roles r on r.key = m.k and r.tenant_id is null;

-- ---------- menu ----------
create table public.menu_categories (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null,
  name text not null, position int not null default 0,
  unique (id, property_id), unique (property_id, name),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade
);
create table public.menu_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null, category_id uuid not null,
  name text not null, price numeric(12,2) not null check (price >= 0),
  tax_rate_percent numeric(5,2) not null default 0 check (tax_rate_percent between 0 and 100),
  active boolean not null default true,
  unique (id, property_id), unique (property_id, name),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade,
  foreign key (category_id, property_id) references public.menu_categories (id, property_id)
);

-- ---------- orders ----------
create table public.orders (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null,
  kind text not null check (kind in ('restaurant', 'room_service')),
  status text not null default 'placed' check (status in ('placed', 'preparing', 'ready', 'served', 'cancelled')),
  reservation_id uuid, unit_id uuid, guest_request_id uuid,
  table_label text, notes text,
  subtotal numeric(12,2) not null default 0, tax numeric(12,2) not null default 0, total numeric(12,2) not null default 0,
  placed_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check (kind <> 'room_service' or reservation_id is not null),
  unique (id, property_id),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade,
  foreign key (reservation_id, property_id) references public.reservations (id, property_id),
  foreign key (unit_id, property_id) references public.accommodation_units (id, property_id),
  foreign key (guest_request_id, property_id) references public.guest_requests (id, property_id)
);
create index on public.orders (property_id, status);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null, order_id uuid not null,
  menu_item_id uuid not null,
  name_snapshot text not null, unit_price numeric(12,2) not null, tax_rate_percent numeric(5,2) not null,
  quantity int not null check (quantity > 0),
  foreign key (order_id, property_id) references public.orders (id, property_id) on delete cascade,
  foreign key (menu_item_id, property_id) references public.menu_items (id, property_id)
);
create table public.kitchen_events (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null, order_id uuid not null,
  event_type text not null, actor_id uuid, created_at timestamptz not null default now(),
  foreign key (order_id, property_id) references public.orders (id, property_id) on delete cascade
);

-- ---------- billing ----------
create table public.folios (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null,
  reservation_id uuid not null unique,
  status text not null default 'open' check (status in ('open', 'closed')),
  currency char(3) not null,
  created_at timestamptz not null default now(), closed_at timestamptz,
  unique (id, property_id),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade,
  foreign key (reservation_id, property_id) references public.reservations (id, property_id)
);
create table public.folio_items (            -- append-only ledger: charges positive, credits negative
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null, folio_id uuid not null,
  kind text not null check (kind in ('room', 'order', 'adjustment')),
  description text not null, amount numeric(12,2) not null,
  order_id uuid, business_date date not null,
  posted_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (folio_id, property_id) references public.folios (id, property_id) on delete cascade,
  foreign key (order_id, property_id) references public.orders (id, property_id)
);
create unique index folio_items_one_room_per_night on public.folio_items (folio_id, business_date) where kind = 'room';
create unique index folio_items_one_per_order on public.folio_items (order_id) where kind = 'order';

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null,
  folio_id uuid, order_id uuid,
  amount numeric(12,2) not null check (amount > 0),
  method text not null check (method in ('cash', 'card', 'upi', 'bank_transfer', 'other')),
  reference text,                         -- opaque processor/receipt reference only; never card data
  collected_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  check (num_nonnulls(folio_id, order_id) = 1),
  unique (id, property_id),
  foreign key (folio_id, property_id) references public.folios (id, property_id),
  foreign key (order_id, property_id) references public.orders (id, property_id)
);
create table public.refunds (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null, payment_id uuid not null,
  amount numeric(12,2) not null check (amount > 0), reason text not null,
  refunded_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (payment_id, property_id) references public.payments (id, property_id)
);
create table public.invoice_counters (
  property_id uuid primary key references public.properties(id) on delete cascade,
  last_number int not null default 0
);
create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null,
  folio_id uuid not null unique, number text not null,
  total numeric(12,2) not null, currency char(3) not null,
  issued_by uuid references public.profiles(id) on delete set null,
  issued_at timestamptz not null default now(),
  unique (property_id, number),
  foreign key (folio_id, property_id) references public.folios (id, property_id)
);
create table public.night_audits (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null,
  business_date date not null, summary jsonb not null,
  run_by uuid references public.profiles(id) on delete set null, run_at timestamptz not null default now(),
  unique (property_id, business_date),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade
);

-- ---------- RLS: reads only; all writes through functions ----------
alter table public.menu_categories enable row level security;
alter table public.menu_items enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.kitchen_events enable row level security;
alter table public.folios enable row level security;
alter table public.folio_items enable row level security;
alter table public.payments enable row level security;
alter table public.refunds enable row level security;
alter table public.invoice_counters enable row level security;
alter table public.invoices enable row level security;
alter table public.night_audits enable row level security;

create policy menu_categories_select on public.menu_categories for select to authenticated using (private.has_property_access(property_id));
create policy menu_items_select on public.menu_items for select to authenticated using (private.has_property_access(property_id));
create policy menu_categories_write on public.menu_categories for all to authenticated
  using (private.has_permission(property_id, 'staff.manage')) with check (private.has_permission(property_id, 'staff.manage'));
create policy menu_items_write on public.menu_items for all to authenticated
  using (private.has_permission(property_id, 'staff.manage')) with check (private.has_permission(property_id, 'staff.manage'));

create policy orders_select on public.orders for select to authenticated
  using (private.has_permission(property_id, 'orders.read') or private.has_permission(property_id, 'orders.place'));
create policy order_items_select on public.order_items for select to authenticated using (exists (select 1 from public.orders o where o.id = order_id));
create policy kitchen_events_select on public.kitchen_events for select to authenticated using (exists (select 1 from public.orders o where o.id = order_id));

create policy folios_select on public.folios for select to authenticated
  using (private.has_permission(property_id, 'billing.manage') or private.has_permission(property_id, 'finance.read'));
create policy folio_items_select on public.folio_items for select to authenticated
  using (private.has_permission(property_id, 'billing.manage') or private.has_permission(property_id, 'finance.read'));
create policy payments_select on public.payments for select to authenticated
  using (private.has_permission(property_id, 'billing.manage') or private.has_permission(property_id, 'finance.read'));
create policy refunds_select on public.refunds for select to authenticated
  using (private.has_permission(property_id, 'billing.manage') or private.has_permission(property_id, 'finance.read'));
create policy invoices_select on public.invoices for select to authenticated
  using (private.has_permission(property_id, 'billing.manage') or private.has_permission(property_id, 'finance.read'));
create policy night_audits_select on public.night_audits for select to authenticated
  using (private.has_permission(property_id, 'billing.manage') or private.has_permission(property_id, 'finance.read'));

-- ---------- billing helpers ----------
create function private.ensure_folio(p_res uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r public.reservations; v uuid;
begin
  select * into r from public.reservations where id = p_res;
  select id into v from public.folios where reservation_id = p_res;
  if v is null then
    insert into public.folios (tenant_id, property_id, reservation_id, currency) values (r.tenant_id, r.property_id, r.id, r.currency)
      on conflict (reservation_id) do nothing returning id into v;
    if v is null then select id into v from public.folios where reservation_id = p_res; end if;
  end if;
  return v;
end $$;

create function private.folio_balance_raw(f uuid) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce((select sum(amount) from public.folio_items where folio_id = f), 0)
       - coalesce((select sum(amount) from public.payments where folio_id = f), 0)
       + coalesce((select sum(rf.amount) from public.refunds rf join public.payments p on p.id = rf.payment_id where p.folio_id = f), 0)
$$;

create function private.reservation_balance(p_res uuid) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce((select private.folio_balance_raw(id) from public.folios where reservation_id = p_res), 0)
$$;

-- Posts every unposted night up to p_through (idempotent). The last night absorbs rounding. Skips closed folios.
create function private.post_room_nights(p_res uuid, p_through date) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r public.reservations; v_folio uuid; d date; v_nights int; v_nightly numeric; v_amt numeric;
begin
  select * into r from public.reservations where id = p_res;
  v_folio := private.ensure_folio(p_res);
  if (select status from public.folios where id = v_folio) = 'closed' then return v_folio; end if;
  v_nights := r.check_out - r.check_in;
  v_nightly := round(r.total_amount / v_nights, 2);
  for d in select g::date from generate_series(r.check_in, least(p_through, r.check_out - 1), interval '1 day') g loop
    v_amt := case when d = r.check_out - 1 then r.total_amount - v_nightly * (v_nights - 1) else v_nightly end;
    insert into public.folio_items (tenant_id, property_id, folio_id, kind, description, amount, business_date, posted_by)
    values (r.tenant_id, r.property_id, v_folio, 'room', 'Room charge ' || d, v_amt, d, auth.uid())
    on conflict (folio_id, business_date) where kind = 'room' do nothing;
  end loop;
  return v_folio;
end $$;

revoke all on function private.ensure_folio(uuid), private.folio_balance_raw(uuid), private.reservation_balance(uuid),
  private.post_room_nights(uuid, date) from public, anon;

-- ---------- orders ----------
create function public.place_order(
  p_property uuid, p_kind text, p_items jsonb, p_reservation uuid default null, p_table text default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_tenant uuid; v_res public.reservations; v_unit uuid; v_id uuid;
  v_sub numeric := 0; v_tax numeric := 0; v_count int := 0; rec record;
begin
  select tenant_id into v_tenant from public.properties where id = p_property;
  if v_tenant is null or not private.has_permission(p_property, 'orders.place') then raise exception 'not permitted' using errcode = '42501'; end if;
  if p_kind not in ('restaurant', 'room_service') then raise exception 'invalid order kind' using errcode = '22023'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'order needs at least one item' using errcode = '22023'; end if;

  if p_reservation is not null then
    select * into v_res from public.reservations where id = p_reservation and property_id = p_property;
    if not found or v_res.status <> 'checked_in' then raise exception 'reservation must be checked in' using errcode = '22023'; end if;
    select unit_id into v_unit from public.unit_holds where reservation_id = p_reservation and active limit 1;
  elsif p_kind = 'room_service' then
    raise exception 'room service needs a reservation' using errcode = '22023';
  end if;

  insert into public.orders (tenant_id, property_id, kind, reservation_id, unit_id, table_label, notes, placed_by)
  values (v_tenant, p_property, p_kind, p_reservation, v_unit, p_table, p_notes, auth.uid()) returning id into v_id;

  for rec in
    select mi.id, mi.name, mi.price, mi.tax_rate_percent, x.quantity
    from jsonb_to_recordset(p_items) as x(menu_item_id uuid, quantity int)
    join public.menu_items mi on mi.id = x.menu_item_id and mi.property_id = p_property and mi.active
  loop
    if rec.quantity is null or rec.quantity < 1 then raise exception 'invalid quantity' using errcode = '22023'; end if;
    insert into public.order_items (tenant_id, property_id, order_id, menu_item_id, name_snapshot, unit_price, tax_rate_percent, quantity)
    values (v_tenant, p_property, v_id, rec.id, rec.name, rec.price, rec.tax_rate_percent, rec.quantity);
    v_sub := v_sub + rec.price * rec.quantity;
    v_tax := v_tax + round(rec.price * rec.quantity * rec.tax_rate_percent / 100, 2);
    v_count := v_count + 1;
  end loop;
  if v_count <> jsonb_array_length(p_items) then raise exception 'unknown or inactive menu item' using errcode = '22023'; end if;

  update public.orders set subtotal = v_sub, tax = v_tax, total = v_sub + v_tax where id = v_id;
  insert into public.kitchen_events (tenant_id, property_id, order_id, event_type, actor_id) values (v_tenant, p_property, v_id, 'placed', auth.uid());
  return v_id;
end $$;

create function public.set_order_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
declare o public.orders; v_folio uuid; v_tz text;
begin
  select * into o from public.orders where id = p_id for update;
  if not found or not (private.has_permission(o.property_id, 'orders.write')
                       or (p_status = 'cancelled' and private.has_permission(o.property_id, 'orders.place'))) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if (o.status, p_status) not in (('placed','preparing'), ('preparing','ready'), ('ready','served'), ('placed','cancelled'), ('preparing','cancelled')) then
    raise exception 'invalid transition % -> %', o.status, p_status using errcode = '22023';
  end if;

  if p_status = 'served' and o.reservation_id is not null then   -- charge to room
    v_folio := private.ensure_folio(o.reservation_id);
    if (select status from public.folios where id = v_folio) = 'closed' then raise exception 'folio is closed' using errcode = '22023'; end if;
    select timezone into v_tz from public.properties where id = o.property_id;
    insert into public.folio_items (tenant_id, property_id, folio_id, kind, description, amount, order_id, business_date, posted_by)
    values (o.tenant_id, o.property_id, v_folio, 'order', 'Order ' || left(o.id::text, 8), o.total, o.id, (now() at time zone v_tz)::date, auth.uid());
  end if;

  update public.orders set status = p_status, updated_at = now() where id = p_id;
  insert into public.kitchen_events (tenant_id, property_id, order_id, event_type, actor_id) values (o.tenant_id, o.property_id, p_id, p_status, auth.uid());
end $$;

-- ---------- billing actions ----------
create function public.post_room_charges(p_reservation uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r public.reservations;
begin
  select * into r from public.reservations where id = p_reservation;
  if not found or not private.has_permission(r.property_id, 'billing.manage') then raise exception 'not permitted' using errcode = '42501'; end if;
  if r.status <> 'checked_in' then raise exception 'reservation is not in house' using errcode = '22023'; end if;
  return private.post_room_nights(p_reservation, r.check_out - 1);
end $$;

create function public.post_folio_charge(p_reservation uuid, p_description text, p_amount numeric) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.reservations; v_folio uuid; v_tz text;
begin
  select * into r from public.reservations where id = p_reservation;
  if not found or not private.has_permission(r.property_id, 'billing.manage') then raise exception 'not permitted' using errcode = '42501'; end if;
  if p_amount < 0 and not private.has_permission(r.property_id, 'finance.write') then raise exception 'credits need finance.write' using errcode = '42501'; end if;
  if p_amount = 0 or coalesce(trim(p_description), '') = '' then raise exception 'description and non-zero amount required' using errcode = '22023'; end if;
  v_folio := private.ensure_folio(p_reservation);
  if (select status from public.folios where id = v_folio) = 'closed' then raise exception 'folio is closed' using errcode = '22023'; end if;
  select timezone into v_tz from public.properties where id = r.property_id;
  insert into public.folio_items (tenant_id, property_id, folio_id, kind, description, amount, business_date, posted_by)
  values (r.tenant_id, r.property_id, v_folio, 'adjustment', p_description, p_amount, (now() at time zone v_tz)::date, auth.uid());
end $$;

create function public.folio_balance(p_folio uuid) returns numeric
language plpgsql stable security definer set search_path = '' as $$
declare f public.folios;
begin
  select * into f from public.folios where id = p_folio;
  if not found or not (private.has_permission(f.property_id, 'billing.manage') or private.has_permission(f.property_id, 'finance.read')) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return private.folio_balance_raw(p_folio);
end $$;

create function public.collect_folio_payment(p_folio uuid, p_amount numeric, p_method text, p_reference text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare f public.folios; v_id uuid;
begin
  select * into f from public.folios where id = p_folio for update;
  if not found or not private.has_permission(f.property_id, 'billing.manage') then raise exception 'not permitted' using errcode = '42501'; end if;
  if f.status <> 'open' then raise exception 'folio is closed' using errcode = '22023'; end if;
  insert into public.payments (tenant_id, property_id, folio_id, amount, method, reference, collected_by)
  values (f.tenant_id, f.property_id, p_folio, p_amount, p_method, p_reference, auth.uid()) returning id into v_id;
  return v_id;
end $$;

-- Walk-in restaurant orders (no room folio) are paid directly, in full, once served.
create function public.collect_order_payment(p_order uuid, p_method text, p_reference text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare o public.orders; v_id uuid;
begin
  select * into o from public.orders where id = p_order for update;
  if not found or not private.has_permission(o.property_id, 'billing.manage') then raise exception 'not permitted' using errcode = '42501'; end if;
  if o.status <> 'served' or o.reservation_id is not null then raise exception 'only served walk-in orders are paid directly' using errcode = '22023'; end if;
  if exists (select 1 from public.payments where order_id = p_order) then raise exception 'order already paid' using errcode = '22023'; end if;
  insert into public.payments (tenant_id, property_id, order_id, amount, method, reference, collected_by)
  values (o.tenant_id, o.property_id, p_order, o.total, p_method, p_reference, auth.uid()) returning id into v_id;
  return v_id;
end $$;

create function public.refund_payment(p_payment uuid, p_amount numeric, p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare p public.payments; v_done numeric; v_id uuid;
begin
  select * into p from public.payments where id = p_payment for update;
  if not found or not private.has_permission(p.property_id, 'finance.write') then raise exception 'not permitted' using errcode = '42501'; end if;
  select coalesce(sum(amount), 0) into v_done from public.refunds where payment_id = p_payment;
  if p_amount <= 0 or p_amount > p.amount - v_done then raise exception 'refund exceeds remaining payment' using errcode = '22023'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason required' using errcode = '22023'; end if;
  insert into public.refunds (tenant_id, property_id, payment_id, amount, reason, refunded_by)
  values (p.tenant_id, p.property_id, p_payment, p_amount, p_reason, auth.uid()) returning id into v_id;
  return v_id;
end $$;

-- Posts any remaining nights, requires a zero balance, numbers the invoice and closes the folio.
-- Numbering is a simple per-property sequence; confirm GST/financial-year rules with counsel before production.
create function public.finalize_invoice(p_folio uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare f public.folios; r public.reservations; v_no int; v_total numeric; v_id uuid;
begin
  select * into f from public.folios where id = p_folio for update;
  if not found or not private.has_permission(f.property_id, 'billing.manage') then raise exception 'not permitted' using errcode = '42501'; end if;
  if f.status <> 'open' then raise exception 'folio is already closed' using errcode = '22023'; end if;
  select * into r from public.reservations where id = f.reservation_id;
  if r.status in ('checked_in', 'checked_out') then perform private.post_room_nights(r.id, r.check_out - 1); end if;
  if private.folio_balance_raw(p_folio) <> 0 then raise exception 'folio balance must be zero before invoicing' using errcode = '22023'; end if;

  insert into public.invoice_counters (property_id, last_number) values (f.property_id, 1)
    on conflict (property_id) do update set last_number = public.invoice_counters.last_number + 1 returning last_number into v_no;
  select coalesce(sum(amount), 0) into v_total from public.folio_items where folio_id = p_folio;
  insert into public.invoices (tenant_id, property_id, folio_id, number, total, currency, issued_by)
  values (f.tenant_id, f.property_id, p_folio, 'INV-' || to_char(now(), 'YYYY') || '-' || lpad(v_no::text, 6, '0'), v_total, f.currency, auth.uid())
  returning id into v_id;
  update public.folios set status = 'closed', closed_at = now() where id = p_folio;
  return v_id;
end $$;

create function public.run_night_audit(p_property uuid, p_date date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_tenant uuid; v_tz text; v_before numeric; v_after numeric; v_n int := 0; v_noshow int; r record; v_summary jsonb;
begin
  select tenant_id, timezone into v_tenant, v_tz from public.properties where id = p_property;
  if v_tenant is null or not private.has_permission(p_property, 'billing.manage') then raise exception 'not permitted' using errcode = '42501'; end if;
  if p_date > (now() at time zone v_tz)::date then raise exception 'cannot audit a future business date' using errcode = '22023'; end if;

  select coalesce(sum(amount), 0) into v_before from public.folio_items where property_id = p_property and kind = 'room';
  for r in select id from public.reservations where property_id = p_property and status = 'checked_in' and check_in <= p_date and p_date < check_out loop
    perform private.post_room_nights(r.id, p_date);
    v_n := v_n + 1;
  end loop;
  select coalesce(sum(amount), 0) into v_after from public.folio_items where property_id = p_property and kind = 'room';
  select count(*) into v_noshow from public.reservations where property_id = p_property and status = 'confirmed' and check_in <= p_date;

  v_summary := jsonb_build_object('reservations_processed', v_n, 'room_revenue_posted', v_after - v_before, 'no_show_candidates', v_noshow);
  insert into public.night_audits (tenant_id, property_id, business_date, summary, run_by) values (v_tenant, p_property, p_date, v_summary, auth.uid())
    on conflict (property_id, business_date) do update set summary = excluded.summary, run_by = excluded.run_by, run_at = now();
  return v_summary;
end $$;

-- ---------- checkout now settles the folio ----------
create or replace function public.check_out_reservation(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.reservations; v record; v_task uuid; v_bal numeric;
begin
  r := private.lock_reservation(p_id, 'frontdesk.manage');
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
  insert into public.reservation_events (tenant_id, property_id, reservation_id, event_type, actor_id)
  values (r.tenant_id, r.property_id, p_id, 'checked_out', auth.uid());
end $$;

revoke execute on function
  public.place_order(uuid, text, jsonb, uuid, text, text), public.set_order_status(uuid, text),
  public.post_room_charges(uuid), public.post_folio_charge(uuid, text, numeric), public.folio_balance(uuid),
  public.collect_folio_payment(uuid, numeric, text, text), public.collect_order_payment(uuid, text, text),
  public.refund_payment(uuid, numeric, text), public.finalize_invoice(uuid), public.run_night_audit(uuid, date)
  from public, anon;
grant execute on function
  public.place_order(uuid, text, jsonb, uuid, text, text), public.set_order_status(uuid, text),
  public.post_room_charges(uuid), public.post_folio_charge(uuid, text, numeric), public.folio_balance(uuid),
  public.collect_folio_payment(uuid, numeric, text, text), public.collect_order_payment(uuid, text, text),
  public.refund_payment(uuid, numeric, text), public.finalize_invoice(uuid), public.run_night_audit(uuid, date)
  to authenticated;
