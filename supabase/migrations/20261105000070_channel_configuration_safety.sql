-- Do not let an in-flight retrieval advance a checkpoint after its connection is reconfigured.
create function private.on_channel_configuration_change() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if old.external_property_id is distinct from new.external_property_id and
 (exists(select 1 from public.channel_unit_mappings where connection_id=new.id) or exists(select 1 from public.channel_booking_state where connection_id=new.id)) then
 raise exception 'A mapped channel cannot be reassigned to another provider hotel. Contact your platform operator.' using errcode='22023';
 end if;
 if old.external_property_id is distinct from new.external_property_id or old.credentials_ref is distinct from new.credentials_ref or old.status is distinct from new.status or old.sandbox_approved is distinct from new.sandbox_approved then
 update public.channel_poll_state set lease_token=null,locked_until=null,next_poll_at=now() where connection_id=new.id;
 end if;
 return new;
end $$;
revoke all on function private.on_channel_configuration_change() from public,anon,authenticated;
create trigger channel_configuration_safety after update of external_property_id,credentials_ref,status,sandbox_approved on public.channel_connections
for each row execute function private.on_channel_configuration_change();
