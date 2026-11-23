-- Resetting a conversation-only profile must not make it appear unused.
create or replace function private.guest_profile_unused(p_guest uuid)returns boolean language sql stable security definer set search_path=''as $$
 select not exists(select 1 from public.reservations where guest_id=p_guest)
 and not exists(select 1 from public.conversations where guest_id=p_guest)
 and not exists(select 1 from public.whatsapp_guest_authorizations where guest_id=p_guest)
 and not exists(select 1 from public.guest_documents where guest_id=p_guest)
 and not exists(select 1 from public.whatsapp_campaign_recipients where guest_id=p_guest)
 and not exists(select 1 from public.messages where consent_confirmation_guest=p_guest)
 and not exists(select 1 from private.guest_identity_audit where guest_id=p_guest and action='reset_whatsapp_link')
$$;
revoke all on function private.guest_profile_unused(uuid)from public,anon,authenticated,service_role;
create index guest_identity_history on private.guest_identity_audit(guest_id,property_id);
