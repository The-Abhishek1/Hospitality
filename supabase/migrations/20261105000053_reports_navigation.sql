-- Orders include kitchen, front desk and finance workflows, each with separate actions.
create or replace function public.workspace_permissions(p_property uuid)returns jsonb
language plpgsql stable security invoker set search_path='' as $$
begin
 if not private.has_property_access(p_property)then raise exception 'property not accessible'using errcode='42501';end if;
 return jsonb_build_object('reservations',private.has_permission(p_property,'reservations.read'),'channels',private.has_permission(p_property,'staff.manage'),
 'inbox',private.has_permission(p_property,'whatsapp.use'),'finance',private.has_permission(p_property,'finance.read')or private.has_permission(p_property,'billing.manage'),
 'requests',private.has_permission(p_property,'guest_requests.read')or private.has_permission(p_property,'guest_requests.manage')or private.has_permission(p_property,'tasks.read'),
 'tasks',private.has_permission(p_property,'tasks.read'),'inventory',private.has_permission(p_property,'inventory.manage'),'orders',private.order_access(p_property),
 'reports',exists(select 1 from jsonb_each_text(private.report_capabilities(p_property))c where c.key<>'link_reservations'and c.value='true'),
 'book',private.has_permission(p_property,'reservations.write'),'frontdesk',private.has_permission(p_property,'frontdesk.manage'));
end $$;
