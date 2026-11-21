-- Hardening: valid IANA timezones, and a tenant can never lose its last owner.

create function private.validate_property_timezone() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = new.timezone) then
    raise exception 'invalid IANA timezone: %', new.timezone using errcode = '22023';
  end if;
  return new;
end $$;

create trigger properties_timezone_check
  before insert or update of timezone on public.properties
  for each row execute function private.validate_property_timezone();

create function private.protect_last_owner() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- Tenant already gone (cascade delete): nothing to protect.
  if not exists (select 1 from public.tenants where id = old.tenant_id) then
    return old;
  end if;
  if old.role = 'owner' and (tg_op = 'DELETE' or new.role <> 'owner')
     and not exists (select 1 from public.tenant_memberships m
                     where m.tenant_id = old.tenant_id and m.role = 'owner' and m.user_id <> old.user_id) then
    raise exception 'a tenant must keep at least one owner' using errcode = '23514';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

create trigger tenant_memberships_last_owner
  before update of role or delete on public.tenant_memberships
  for each row execute function private.protect_last_owner();
