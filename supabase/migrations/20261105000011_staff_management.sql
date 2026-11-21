-- Staff management: invite by email, accept after the invitee signs up with a CONFIRMED matching email,
-- assign per-property roles, remove access. No service-role key is needed anywhere; the web app calls these RPCs.
-- Nothing is emailed by the database: the inviter must tell the person to sign up with the invited address.

alter table public.profiles add column email text;
update public.profiles p set email = lower(u.email) from auth.users u where u.id = p.id;

create or replace function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, full_name, email)
  values (new.id, new.raw_user_meta_data ->> 'full_name', lower(new.email));
  return new;
end $$;

create table public.staff_invitations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  email text not null check (email = lower(email) and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  tenant_role text not null check (tenant_role in ('admin', 'member')),   -- owners are never created by invitation
  grants jsonb not null default '[]',                                       -- [{property_id, role_key}]
  status text not null default 'pending' check (status in ('pending', 'accepted', 'revoked')),
  expires_at timestamptz not null default now() + interval '14 days',
  invited_by uuid references public.profiles(id) on delete set null,
  accepted_by uuid references public.profiles(id) on delete set null, accepted_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index staff_invitations_one_pending on public.staff_invitations (tenant_id, email) where status = 'pending';

alter table public.staff_invitations enable row level security;
create policy invitations_select on public.staff_invitations for select to authenticated using (private.is_tenant_admin(tenant_id));

create function public.invite_staff(p_tenant uuid, p_email text, p_tenant_role text, p_grants jsonb default '[]') returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_email text := lower(trim(p_email)); g jsonb; v_id uuid;
begin
  if not private.is_tenant_admin(p_tenant) then raise exception 'not permitted' using errcode = '42501'; end if;
  if p_tenant_role not in ('admin', 'member') then raise exception 'role must be admin or member' using errcode = '22023'; end if;
  if jsonb_typeof(p_grants) <> 'array' then raise exception 'grants must be an array' using errcode = '22023'; end if;
  for g in select * from jsonb_array_elements(p_grants) loop
    if not exists (select 1 from public.properties where id = (g ->> 'property_id')::uuid and tenant_id = p_tenant) then
      raise exception 'property does not belong to this tenant' using errcode = '22023';
    end if;
    if not exists (select 1 from public.roles where key = g ->> 'role_key' and (tenant_id is null or tenant_id = p_tenant)) then
      raise exception 'unknown role %', g ->> 'role_key' using errcode = '22023';
    end if;
  end loop;
  insert into public.staff_invitations (tenant_id, email, tenant_role, grants, invited_by)
  values (p_tenant, v_email, p_tenant_role, p_grants, auth.uid()) returning id into v_id;   -- unique pending per email -> 23505
  return v_id;
end $$;

create function public.revoke_staff_invitation(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare i public.staff_invitations;
begin
  select * into i from public.staff_invitations where id = p_id;
  if not found or not private.is_tenant_admin(i.tenant_id) then raise exception 'not permitted' using errcode = '42501'; end if;
  update public.staff_invitations set status = 'revoked' where id = p_id and status = 'pending';
end $$;

-- Called by the web app after sign-in. Only a confirmed email can claim invitations addressed to it.
create function public.accept_staff_invitations() returns int
language plpgsql security definer set search_path = '' as $$
declare v_email text; v_conf timestamptz; inv public.staff_invitations; g record; n int := 0;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  select lower(email), email_confirmed_at into v_email, v_conf from auth.users where id = auth.uid();
  if v_conf is null or v_email is null then return 0; end if;

  for inv in select * from public.staff_invitations where status = 'pending' and email = v_email and expires_at > now() for update loop
    insert into public.tenant_memberships (tenant_id, user_id, role) values (inv.tenant_id, auth.uid(), inv.tenant_role)
      on conflict do nothing;                       -- an existing membership is never upgraded by an invitation
    for g in select (x ->> 'property_id')::uuid as pid, x ->> 'role_key' as rk from jsonb_array_elements(inv.grants) x loop
      insert into public.property_memberships (property_id, tenant_id, user_id) values (g.pid, inv.tenant_id, auth.uid()) on conflict do nothing;
      insert into public.user_roles (property_id, user_id, role_id)
        select g.pid, auth.uid(), r.id from public.roles r where r.key = g.rk and (r.tenant_id is null or r.tenant_id = inv.tenant_id)
        on conflict do nothing;
    end loop;
    update public.staff_invitations set status = 'accepted', accepted_by = auth.uid(), accepted_at = now() where id = inv.id;
    n := n + 1;
  end loop;
  return n;
end $$;

create function public.set_staff_access(p_property uuid, p_user uuid, p_role_keys text[]) returns void
language plpgsql security definer set search_path = '' as $$
declare v_tenant uuid; v_ids uuid[]; v_target text;
begin
  select tenant_id into v_tenant from public.properties where id = p_property;
  if v_tenant is null or not private.is_tenant_admin(v_tenant) then raise exception 'not permitted' using errcode = '42501'; end if;
  select role into v_target from public.tenant_memberships where tenant_id = v_tenant and user_id = p_user;
  if v_target is null then raise exception 'not a member of this tenant' using errcode = '22023'; end if;
  if v_target in ('owner', 'admin') then raise exception 'owners and admins already have full access' using errcode = '22023'; end if;

  select coalesce(array_agg(id), '{}') into v_ids from public.roles where key = any (p_role_keys) and (tenant_id is null or tenant_id = v_tenant);
  if coalesce(array_length(p_role_keys, 1), 0) <> coalesce(array_length(v_ids, 1), 0) then raise exception 'unknown role' using errcode = '22023'; end if;

  if array_length(v_ids, 1) is null then            -- no roles = no access to this property
    delete from public.property_memberships where property_id = p_property and user_id = p_user;
    return;
  end if;
  insert into public.property_memberships (property_id, tenant_id, user_id) values (p_property, v_tenant, p_user) on conflict do nothing;
  delete from public.user_roles where property_id = p_property and user_id = p_user and role_id <> all (v_ids);
  insert into public.user_roles (property_id, user_id, role_id) select p_property, p_user, unnest(v_ids) on conflict do nothing;
end $$;

create function public.set_tenant_role(p_tenant uuid, p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_tenant_owner(p_tenant) then raise exception 'not permitted' using errcode = '42501'; end if;
  if p_role not in ('owner', 'admin', 'member') then raise exception 'invalid role' using errcode = '22023'; end if;
  update public.tenant_memberships set role = p_role where tenant_id = p_tenant and user_id = p_user;   -- last-owner trigger guards demotion
  if not found then raise exception 'not a member' using errcode = '22023'; end if;
end $$;

create function public.remove_staff(p_tenant uuid, p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_target text;
begin
  if not private.is_tenant_admin(p_tenant) then raise exception 'not permitted' using errcode = '42501'; end if;
  select role into v_target from public.tenant_memberships where tenant_id = p_tenant and user_id = p_user;
  if v_target is null then raise exception 'not a member' using errcode = '22023'; end if;
  if v_target = 'owner' and not private.is_tenant_owner(p_tenant) then raise exception 'only an owner can remove an owner' using errcode = '42501'; end if;
  delete from public.tenant_memberships where tenant_id = p_tenant and user_id = p_user;   -- cascades property access and roles; last owner is protected
end $$;

revoke execute on function
  public.invite_staff(uuid, text, text, jsonb), public.revoke_staff_invitation(uuid), public.accept_staff_invitations(),
  public.set_staff_access(uuid, uuid, text[]), public.set_tenant_role(uuid, uuid, text), public.remove_staff(uuid, uuid)
  from public, anon;
grant execute on function
  public.invite_staff(uuid, text, text, jsonb), public.revoke_staff_invitation(uuid), public.accept_staff_invitations(),
  public.set_staff_access(uuid, uuid, text[]), public.set_tenant_role(uuid, uuid, text), public.remove_staff(uuid, uuid)
  to authenticated;
