-- Lightweight permissions for the shared shell; data access remains enforced by RLS.
create function public.workspace_permissions(p_property uuid) returns jsonb
language plpgsql stable security invoker set search_path = '' as $$
begin
  if not private.has_property_access(p_property) then raise exception 'property not accessible' using errcode = '42501'; end if;
  return jsonb_build_object(
    'reservations',private.has_permission(p_property,'reservations.read'),
    'channels',private.has_permission(p_property,'staff.manage'),
    'inbox',private.has_permission(p_property,'whatsapp.use'),
    'finance',private.has_permission(p_property,'finance.read') or private.has_permission(p_property,'billing.manage'),
    'requests',private.has_permission(p_property,'guest_requests.read'),
    'tasks',private.has_permission(p_property,'tasks.read'),
    'inventory',private.has_permission(p_property,'inventory.manage'),
    'orders',private.has_permission(p_property,'orders.read'));
end $$;
revoke all on function public.workspace_permissions(uuid) from public, anon;
grant execute on function public.workspace_permissions(uuid) to authenticated;
