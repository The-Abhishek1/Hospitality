-- Declining automatic updates does not erase previously verified booking identity.
-- A guest-initiated post-stay request can use that proof; STOP and staff resets still win.
create or replace function private.restore_poststay_identity(p_conversation uuid)returns void language plpgsql security definer set search_path=''as $$
declare c public.conversations;gid uuid;begin
 select *into c from public.conversations where id=p_conversation for update;if c.guest_id is not null then return;end if;
 select case when count(distinct proof.guest_id)=1 then(array_agg(distinct proof.guest_id))[1]end into gid from(
  select a.guest_id from public.whatsapp_guest_authorizations a where a.property_id=c.property_id and a.conversation_id=c.id and a.wa_contact_id=c.wa_contact_id and a.status='granted'
  union select b.guest_id from private.whatsapp_booking_contacts b where b.property_id=c.property_id and b.conversation_id=c.id and b.phone=c.wa_contact_id
 )proof join public.guests g on g.id=proof.guest_id and private.campaign_phone(g.phone)=c.wa_contact_id where exists(select 1 from public.reservations r where r.property_id=c.property_id and r.guest_id=proof.guest_id and r.status='checked_out');
 if gid is null or exists(select 1 from public.reservations r join public.guests g on g.id=r.guest_id join public.properties p on p.id=r.property_id where r.property_id=c.property_id and r.status in('confirmed','checked_in')and r.check_out>=(now()at time zone p.timezone)::date and private.campaign_phone(g.phone)=c.wa_contact_id)then return;end if;
 update public.conversations set guest_id=gid where id=c.id;
end $$;
revoke all on function private.restore_poststay_identity(uuid)from public,anon,authenticated,service_role;
