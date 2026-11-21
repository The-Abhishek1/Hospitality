-- Shared system roles have no tenant and must remain visible under their existing policy.
alter policy platform_account_active on public.roles
 using(tenant_id is null or private.tenant_is_active(tenant_id))
 with check(tenant_id is null or private.tenant_is_active(tenant_id));

-- Even a platform administrator who also owns a business must use audited commands.
-- Invoker context distinguishes direct client updates from the definer command path.
create or replace function private.guard_platform_status()returns trigger
language plpgsql security invoker set search_path=''as $$
begin
 if current_user in('authenticated','anon')and(new.status is distinct from old.status or new.admin_version is distinct from old.admin_version)then
  raise exception 'Use the audited platform administration command to change account status.'using errcode='42501';
 end if;
 return new;
end $$;
