-- INSERT ... RETURNING checks SELECT policies before a stable helper can
-- look up the newly inserted property. Check tenant admins on the row directly.
alter policy properties_select on public.properties
  using (private.is_tenant_admin(tenant_id) or private.has_property_access(id));
