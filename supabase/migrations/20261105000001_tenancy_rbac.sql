-- Milestone 1: tenancy, memberships, RBAC, RLS.
-- tenant = business, property = site; memberships are separate from both.
-- Child tables carry tenant_id and use composite FKs so cross-tenant references are impossible.

create schema if not exists private;

-- ---------- profiles ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone text,
  created_at timestamptz not null default now()
);

create function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, new.raw_user_meta_data ->> 'full_name');
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- ---------- tenancy ----------
create table public.tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(name) between 2 and 120),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$'),
  status text not null default 'active' check (status in ('active', 'suspended', 'closed')),
  created_at timestamptz not null default now()
);

create table public.properties (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null check (length(name) between 2 and 120),
  property_type text not null check (property_type in ('hotel', 'resort', 'hostel', 'homestay')),
  timezone text not null default 'Asia/Kolkata',   -- IANA name; timestamps stored in UTC
  currency char(3) not null default 'INR',
  created_at timestamptz not null default now(),
  unique (id, tenant_id)                            -- target for composite FKs
);
create index on public.properties (tenant_id);

create table public.tenant_memberships (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null check (role in ('owner', 'admin', 'member')),
  created_at timestamptz not null default now(),
  primary key (tenant_id, user_id)
);
create index on public.tenant_memberships (user_id);

create table public.property_memberships (
  property_id uuid not null,
  tenant_id uuid not null,
  user_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (property_id, user_id),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade,
  foreign key (tenant_id, user_id) references public.tenant_memberships (tenant_id, user_id) on delete cascade
);
create index on public.property_memberships (user_id);

-- ---------- RBAC ----------
create table public.permissions (
  key text primary key,
  description text not null
);

create table public.roles (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references public.tenants(id) on delete cascade,  -- null = system role
  key text not null,
  name text not null,
  unique nulls not distinct (tenant_id, key)
);

create table public.role_permissions (
  role_id uuid not null references public.roles(id) on delete cascade,
  permission_key text not null references public.permissions(key) on delete cascade,
  primary key (role_id, permission_key)
);

create table public.user_roles (
  property_id uuid not null,
  user_id uuid not null,
  role_id uuid not null references public.roles(id) on delete cascade,
  primary key (property_id, user_id, role_id),
  foreign key (property_id, user_id) references public.property_memberships (property_id, user_id) on delete cascade
);

-- A role must be a system role or belong to the same tenant as the property.
create function private.check_user_role_tenant() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (
    select 1
    from public.roles r
    join public.properties p on p.id = new.property_id
    where r.id = new.role_id and (r.tenant_id is null or r.tenant_id = p.tenant_id)
  ) then
    raise exception 'role does not belong to this property''s tenant' using errcode = '23514';
  end if;
  return new;
end $$;

create trigger user_roles_tenant_check
  before insert or update on public.user_roles
  for each row execute function private.check_user_role_tenant();

-- ---------- authorization helpers (identity always from auth.uid()) ----------
create function private.is_tenant_member(t uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.tenant_memberships m
                 where m.tenant_id = t and m.user_id = (select auth.uid()))
$$;

create function private.is_tenant_admin(t uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.tenant_memberships m
                 where m.tenant_id = t and m.user_id = (select auth.uid())
                   and m.role in ('owner', 'admin'))
$$;

create function private.is_tenant_owner(t uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.tenant_memberships m
                 where m.tenant_id = t and m.user_id = (select auth.uid()) and m.role = 'owner')
$$;

create function private.has_property_access(p uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.properties pr
    where pr.id = p
      and (private.is_tenant_admin(pr.tenant_id)
           or exists (select 1 from public.property_memberships pm
                      where pm.property_id = p and pm.user_id = (select auth.uid())))
  )
$$;

-- Tenant owners/admins implicitly hold every permission on their tenant's properties.
create function private.has_permission(p uuid, perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.properties pr
    where pr.id = p
      and (private.is_tenant_admin(pr.tenant_id)
           or exists (select 1
                      from public.user_roles ur
                      join public.role_permissions rp on rp.role_id = ur.role_id
                      where ur.property_id = p
                        and ur.user_id = (select auth.uid())
                        and rp.permission_key = perm))
  )
$$;

revoke all on all functions in schema private from public, anon;
grant usage on schema private to authenticated;
grant execute on all functions in schema private to authenticated;

-- ---------- RLS ----------
alter table public.profiles enable row level security;
alter table public.tenants enable row level security;
alter table public.properties enable row level security;
alter table public.tenant_memberships enable row level security;
alter table public.property_memberships enable row level security;
alter table public.permissions enable row level security;
alter table public.roles enable row level security;
alter table public.role_permissions enable row level security;
alter table public.user_roles enable row level security;

create policy profiles_select_own on public.profiles for select to authenticated
  using (id = (select auth.uid()));
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- tenants are created only via create_tenant(); no insert/delete policy on purpose.
create policy tenants_select on public.tenants for select to authenticated
  using (private.is_tenant_member(id));
create policy tenants_update on public.tenants for update to authenticated
  using (private.is_tenant_admin(id)) with check (private.is_tenant_admin(id));

create policy properties_select on public.properties for select to authenticated
  using (private.has_property_access(id));
create policy properties_insert on public.properties for insert to authenticated
  with check (private.is_tenant_admin(tenant_id));
create policy properties_update on public.properties for update to authenticated
  using (private.is_tenant_admin(tenant_id)) with check (private.is_tenant_admin(tenant_id));
create policy properties_delete on public.properties for delete to authenticated
  using (private.is_tenant_owner(tenant_id));

create policy tenant_memberships_select on public.tenant_memberships for select to authenticated
  using (private.is_tenant_member(tenant_id));
create policy tenant_memberships_write on public.tenant_memberships for all to authenticated
  using (private.is_tenant_owner(tenant_id)) with check (private.is_tenant_owner(tenant_id));

create policy property_memberships_select on public.property_memberships for select to authenticated
  using (private.is_tenant_member(tenant_id));
create policy property_memberships_write on public.property_memberships for all to authenticated
  using (private.is_tenant_admin(tenant_id)) with check (private.is_tenant_admin(tenant_id));

create policy permissions_select on public.permissions for select to authenticated using (true);
create policy roles_select on public.roles for select to authenticated
  using (tenant_id is null or private.is_tenant_member(tenant_id));
create policy roles_write on public.roles for all to authenticated
  using (tenant_id is not null and private.is_tenant_admin(tenant_id))
  with check (tenant_id is not null and private.is_tenant_admin(tenant_id));
create policy role_permissions_select on public.role_permissions for select to authenticated
  using (exists (select 1 from public.roles r where r.id = role_id));

create policy user_roles_select on public.user_roles for select to authenticated
  using (private.has_property_access(property_id));
create policy user_roles_write on public.user_roles for all to authenticated
  using (exists (select 1 from public.properties p where p.id = property_id and private.is_tenant_admin(p.tenant_id)))
  with check (exists (select 1 from public.properties p where p.id = property_id and private.is_tenant_admin(p.tenant_id)));

-- ---------- onboarding RPC ----------
create function public.create_tenant(p_name text, p_slug text) returns uuid
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
  return v_id;
end $$;
revoke execute on function public.create_tenant(text, text) from public, anon;
grant execute on function public.create_tenant(text, text) to authenticated;

-- ---------- reference data ----------
insert into public.permissions (key, description) values
  ('reservations.read',    'View reservations'),
  ('reservations.write',   'Create and modify reservations'),
  ('frontdesk.manage',     'Check-in, check-out, room assignment'),
  ('tasks.read',           'View internal tasks'),
  ('tasks.write',          'Update internal tasks'),
  ('tasks.assign',         'Create and assign internal tasks'),
  ('guest_requests.read',  'View guest requests'),
  ('guest_requests.manage','Triage and resolve guest requests'),
  ('housekeeping.manage',  'Manage room status and turnover'),
  ('orders.read',          'View restaurant/room-service orders'),
  ('orders.write',         'Update order and kitchen status'),
  ('finance.read',         'View folios, invoices, payments'),
  ('finance.write',        'Post charges, payments, refunds'),
  ('staff.manage',         'Manage staff and roles');

insert into public.roles (tenant_id, key, name) values
  (null, 'manager',      'Manager'),
  (null, 'front_desk',   'Front desk'),
  (null, 'housekeeping', 'Housekeeping'),
  (null, 'maintenance',  'Maintenance'),
  (null, 'kitchen',      'Kitchen'),
  (null, 'accountant',   'Accountant');

insert into public.role_permissions (role_id, permission_key)
select r.id, m.perm
from (values
  ('manager','reservations.read'),('manager','reservations.write'),('manager','frontdesk.manage'),
  ('manager','tasks.read'),('manager','tasks.write'),('manager','tasks.assign'),
  ('manager','guest_requests.read'),('manager','guest_requests.manage'),('manager','housekeeping.manage'),
  ('manager','orders.read'),('manager','orders.write'),('manager','finance.read'),('manager','staff.manage'),
  ('front_desk','reservations.read'),('front_desk','reservations.write'),('front_desk','frontdesk.manage'),
  ('front_desk','guest_requests.read'),('front_desk','guest_requests.manage'),('front_desk','tasks.read'),
  ('housekeeping','tasks.read'),('housekeeping','tasks.write'),('housekeeping','housekeeping.manage'),
  ('maintenance','tasks.read'),('maintenance','tasks.write'),
  ('kitchen','orders.read'),('kitchen','orders.write'),('kitchen','tasks.read'),
  ('accountant','finance.read'),('accountant','finance.write'),('accountant','reservations.read')
) as m(role_key, perm)
join public.roles r on r.key = m.role_key and r.tenant_id is null;
