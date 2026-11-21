-- Milestone 2: platform admin, plans, entitlements, subscriptions, usage, audit.
-- Platform admins see tenant-level data only (tenants, subscriptions, usage).
-- Access to a tenant's property/guest data needs a separate, audited support-session mechanism (not built yet).

create table public.platform_admins (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);

create function private.is_platform_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.platform_admins where user_id = (select auth.uid()))
$$;

create table public.plans (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  name text not null,
  price_monthly numeric(12,2) not null check (price_monthly >= 0),
  currency char(3) not null default 'INR',
  active boolean not null default true
);

-- value is a JSON scalar: a number for limits, boolean for feature flags. Missing key = unlimited/unavailable per feature.
create table public.plan_entitlements (
  plan_id uuid not null references public.plans(id) on delete cascade,
  key text not null,
  value jsonb not null,
  primary key (plan_id, key)
);

create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null unique references public.tenants(id) on delete cascade,
  plan_id uuid not null references public.plans(id),
  status text not null check (status in ('trialing', 'active', 'past_due', 'canceled')),
  current_period_end timestamptz,
  created_at timestamptz not null default now()
);

create table public.usage_records (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  property_id uuid,
  metric text not null,
  quantity numeric not null check (quantity >= 0),
  recorded_at timestamptz not null default now(),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade
);
create index on public.usage_records (tenant_id, metric, recorded_at);

create table public.platform_audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.profiles(id) on delete set null,
  action text not null,
  tenant_id uuid references public.tenants(id) on delete set null,
  details jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index on public.platform_audit_logs (tenant_id, created_at desc);

-- ---------- entitlements ----------
create function private.entitlement(t uuid, k text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select pe.value
  from public.subscriptions s
  join public.plan_entitlements pe on pe.plan_id = s.plan_id
  where s.tenant_id = t and s.status in ('trialing', 'active', 'past_due') and pe.key = k
$$;

create function private.enforce_property_limit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v jsonb := private.entitlement(new.tenant_id, 'max_properties');
begin
  if v is not null
     and (select count(*) from public.properties where tenant_id = new.tenant_id) >= (v #>> '{}')::int then
    raise exception 'property limit reached for current plan' using errcode = '53400';
  end if;
  return new;
end $$;

create trigger properties_limit before insert on public.properties
  for each row execute function private.enforce_property_limit();

revoke all on function private.is_platform_admin(), private.entitlement(uuid, text) from public, anon;
grant execute on function private.is_platform_admin(), private.entitlement(uuid, text) to authenticated;

-- ---------- RLS ----------
alter table public.platform_admins enable row level security;
alter table public.plans enable row level security;
alter table public.plan_entitlements enable row level security;
alter table public.subscriptions enable row level security;
alter table public.usage_records enable row level security;
alter table public.platform_audit_logs enable row level security;

create policy platform_admins_select_own on public.platform_admins for select to authenticated
  using (user_id = (select auth.uid()));
create policy plans_select on public.plans for select to authenticated using (active or private.is_platform_admin());
create policy plan_entitlements_select on public.plan_entitlements for select to authenticated using (true);
create policy plans_admin_write on public.plans for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());
create policy plan_entitlements_admin_write on public.plan_entitlements for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy subscriptions_select on public.subscriptions for select to authenticated
  using (private.is_tenant_member(tenant_id) or private.is_platform_admin());
create policy usage_select on public.usage_records for select to authenticated
  using (private.is_tenant_admin(tenant_id) or private.is_platform_admin());
create policy audit_select on public.platform_audit_logs for select to authenticated
  using (private.is_platform_admin());
-- No client write policies on subscriptions, usage or audit: writes go through definer RPCs or the service role.

create policy tenants_platform_select on public.tenants for select to authenticated
  using (private.is_platform_admin());

-- ---------- admin RPCs (every call is audited) ----------
create function public.admin_assign_plan(p_tenant uuid, p_plan_key text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_plan uuid;
begin
  if not private.is_platform_admin() then
    raise exception 'platform admin only' using errcode = '42501';
  end if;
  select id into v_plan from public.plans where key = p_plan_key and active;
  if v_plan is null then raise exception 'unknown plan' using errcode = '22023'; end if;
  insert into public.subscriptions (tenant_id, plan_id, status) values (p_tenant, v_plan, 'active')
    on conflict (tenant_id) do update set plan_id = excluded.plan_id, status = 'active';
  insert into public.platform_audit_logs (actor_id, action, tenant_id, details)
    values (auth.uid(), 'plan_assigned', p_tenant, jsonb_build_object('plan', p_plan_key));
end $$;

create function public.admin_set_tenant_status(p_tenant uuid, p_status text, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_platform_admin() then
    raise exception 'platform admin only' using errcode = '42501';
  end if;
  if coalesce(length(trim(p_reason)), 0) < 3 then
    raise exception 'a reason is required' using errcode = '22023';
  end if;
  update public.tenants set status = p_status where id = p_tenant;
  insert into public.platform_audit_logs (actor_id, action, tenant_id, details)
    values (auth.uid(), 'tenant_status_changed', p_tenant, jsonb_build_object('status', p_status, 'reason', p_reason));
end $$;

revoke execute on function public.admin_assign_plan(uuid, text), public.admin_set_tenant_status(uuid, text, text) from public, anon;
grant execute on function public.admin_assign_plan(uuid, text), public.admin_set_tenant_status(uuid, text, text) to authenticated;

-- ---------- seed plans ----------
insert into public.plans (key, name, price_monthly) values
  ('starter', 'Starter', 0), ('growth', 'Growth', 2999), ('enterprise', 'Enterprise', 9999);
insert into public.plan_entitlements (plan_id, key, value)
select p.id, e.k, e.v::jsonb from public.plans p join (values
  ('starter','max_properties','2'), ('starter','channel_manager','false'), ('starter','whatsapp','false'),
  ('growth','max_properties','10'), ('growth','channel_manager','true'), ('growth','whatsapp','true'),
  ('enterprise','channel_manager','true'), ('enterprise','whatsapp','true')   -- no max_properties = unlimited
) as e(pk, k, v) on e.pk = p.key;

-- ---------- onboarding now starts a 14-day trial ----------
create or replace function public.create_tenant(p_name text, p_slug text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  insert into public.tenants (name, slug) values (p_name, p_slug) returning id into v_id;
  insert into public.tenant_memberships (tenant_id, user_id, role) values (v_id, v_uid, 'owner');
  insert into public.subscriptions (tenant_id, plan_id, status, current_period_end)
    select v_id, id, 'trialing', now() + interval '14 days' from public.plans where key = 'starter';
  return v_id;
end $$;
