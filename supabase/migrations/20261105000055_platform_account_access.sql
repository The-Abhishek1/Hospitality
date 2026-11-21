-- Suspension blocks authenticated hotel operations and token-based guest portal access.
create function private.tenant_is_active(p_tenant uuid)returns boolean language sql stable security definer set search_path=''as $$select exists(select 1 from public.tenants where id=p_tenant and status='active')$$;
revoke all on function private.tenant_is_active(uuid)from public,anon;
grant execute on function private.tenant_is_active(uuid)to authenticated;
create or replace function private.is_tenant_admin(t uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.tenant_memberships m
                 where private.tenant_is_active(t) and m.tenant_id = t and m.user_id = (select auth.uid())
                   and m.role in ('owner', 'admin'))
$$;
create or replace function private.is_tenant_owner(t uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.tenant_memberships m
                 where private.tenant_is_active(t) and m.tenant_id = t and m.user_id = (select auth.uid()) and m.role = 'owner')
$$;
create or replace function private.has_property_access(p uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.properties pr
    where private.tenant_is_active(pr.tenant_id) and pr.id = p
      and (private.is_tenant_admin(pr.tenant_id)
           or exists (select 1 from public.property_memberships pm
                      where pm.property_id = p and pm.user_id = (select auth.uid())))
  )
$$;
create or replace function private.has_permission(p uuid, perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.properties pr
    where private.tenant_is_active(pr.tenant_id) and pr.id = p
      and (private.is_tenant_admin(pr.tenant_id)
           or exists (select 1
                      from public.user_roles ur
                      join public.role_permissions rp on rp.role_id = ur.role_id
                      where ur.property_id = p
                        and ur.user_id = (select auth.uid())
                        and rp.permission_key = perm))
  )
$$;
-- RLS also denies direct client access to suspended operational rows.
do $$declare r record;begin
 for r in select c.table_name from information_schema.columns c join information_schema.tables t using(table_schema,table_name)where c.table_schema='public'and c.column_name='tenant_id'and t.table_type='BASE TABLE'and c.table_name not in('subscriptions','usage_records','platform_audit_logs')loop
 execute format('create policy platform_account_active on public.%I as restrictive for all to authenticated using(private.tenant_is_active(tenant_id))with check(private.tenant_is_active(tenant_id))',r.table_name);
 end loop;
end $$;
create function private.guard_platform_status()returns trigger language plpgsql security definer set search_path=''as $$
begin
 if auth.uid()is not null and(new.status is distinct from old.status or new.admin_version is distinct from old.admin_version)and not private.is_platform_admin()then raise exception 'Only platform administrators can change account status.'using errcode='42501';end if;
 return new;
end $$;
revoke all on function private.guard_platform_status()from public,anon,authenticated;
create trigger guard_platform_status before update of status,admin_version on public.tenants for each row execute function private.guard_platform_status();
create or replace function private.portal_reservation(p_token text) returns public.reservations
language plpgsql security definer set search_path = '' as $$
declare t public.guest_access_tokens; r public.reservations;
begin
  select * into t from public.guest_access_tokens where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'utf8')), 'hex');
  if not found or t.revoked_at is not null or t.expires_at < now() then
    raise exception 'invalid or expired link' using errcode = '28000';
  end if;
  if not exists(select 1 from public.reservations r join public.tenants b on b.id=r.tenant_id where r.id=t.reservation_id and b.status='active')then raise exception 'Hotel access is currently unavailable.'using errcode='42501';end if;
  update public.guest_access_tokens set last_used_at = now(), use_count = use_count + 1 where id = t.id;
  select * into r from public.reservations where id = t.reservation_id;
  return r;
end $$;
