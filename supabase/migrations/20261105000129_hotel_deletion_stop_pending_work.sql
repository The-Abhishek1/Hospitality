-- A cleanup interrupted during Storage removal must not leave queued work that
-- repeatedly retries against the frozen hotel. Runs before the freeze row exists.
create function private.stop_deleted_hotel_work()returns trigger
language plpgsql security definer set search_path=''as $$
begin
 update public.whatsapp_automation_events set state='skipped',reason='Hotel permanent deletion in progress.'where property_id=new.property_id and state in('pending','blocked','queued');
 update public.whatsapp_campaign_recipients set state='skipped',skip_reason='Hotel permanent deletion in progress.'where property_id=new.property_id and state in('pending','queued');
 update public.whatsapp_default_setup set enabled=false,lease=null,locked_at=null,version=version+1 where property_id=new.property_id;
 update public.whatsapp_journey_settings set enabled=false,version=version+1 where property_id=new.property_id and enabled;
 update private.whatsapp_setup_sessions set consumed=true where property_id=new.property_id and not consumed;
 update private.whatsapp_consent_challenges set cancelled_at=now()where property_id=new.property_id and consumed_at is null and cancelled_at is null;
 update private.whatsapp_guest_inbound_jobs set state='done'where state='pending'and message_id in(select id from public.messages where property_id=new.property_id);
 return new;
end $$;
revoke all on function private.stop_deleted_hotel_work()from public,anon,authenticated,service_role;
create trigger stop_deleted_hotel_work before insert on private.hotel_deletions for each row execute function private.stop_deleted_hotel_work();
