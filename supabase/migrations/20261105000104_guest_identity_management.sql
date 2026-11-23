-- Correct a hotel-specific WhatsApp binding without deleting reservation/billing history.
create table private.guest_identity_audit(
 id uuid primary key default gen_random_uuid(),property_id uuid not null references public.properties(id),
 guest_id uuid not null,actor_id uuid not null,action text not null,reason text not null,
 details jsonb not null,created_at timestamptz not null default clock_timestamp()
);
revoke all on private.guest_identity_audit from public,anon,authenticated,service_role;
create policy guests_delete_command_only on public.guests as restrictive for delete to authenticated using(false);

alter table public.messages add column guest_identity_reset_at timestamptz;
create function private.guard_reset_guest_message()returns trigger language plpgsql set search_path=''as $$
begin
 if old.guest_identity_reset_at is not null and new.status in('queued','sending')then
  raise exception 'This message belongs to a reset guest link. Create a new message for the verified guest.'using errcode='22023';
 end if;
 if old.guest_identity_reset_at is not null then new.guest_identity_reset_at:=old.guest_identity_reset_at;end if;
 return new;
end $$;
revoke all on function private.guard_reset_guest_message()from public,anon,authenticated,service_role;
create trigger guest_message_reset_guard before update on public.messages for each row execute function private.guard_reset_guest_message();
alter function private.inbox_delivery_error(uuid)rename to inbox_delivery_error_before_identity_reset;
revoke all on function private.inbox_delivery_error_before_identity_reset(uuid)from public,anon,authenticated,service_role;
create function private.inbox_delivery_error(p_message uuid)returns text language plpgsql stable security definer set search_path=''as $$
begin
 if exists(select 1 from public.messages where id=p_message and guest_identity_reset_at is not null)then return 'Guest WhatsApp link was reset. Verify the guest and create a new message.';end if;
 return private.inbox_delivery_error_before_identity_reset(p_message);
end $$;
revoke all on function private.inbox_delivery_error(uuid)from public,anon,authenticated,service_role;

create function private.guest_profile_unused(p_guest uuid)returns boolean language sql stable security definer set search_path=''as $$
 select not exists(select 1 from public.reservations where guest_id=p_guest)
 and not exists(select 1 from public.conversations where guest_id=p_guest)
 and not exists(select 1 from public.whatsapp_guest_authorizations where guest_id=p_guest)
 and not exists(select 1 from public.guest_documents where guest_id=p_guest)
 and not exists(select 1 from public.whatsapp_campaign_recipients where guest_id=p_guest)
 and not exists(select 1 from public.messages where consent_confirmation_guest=p_guest)
$$;
revoke all on function private.guest_profile_unused(uuid)from public,anon,authenticated,service_role;

create function public.guest_identity_workspace(p_property uuid,p_query text default '',p_page integer default 1)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare tenant uuid;owner_access boolean;result jsonb;
begin
 if not private.has_permission(p_property,'staff.manage')or not private.has_permission(p_property,'reservations.write')then raise exception 'Hotel administrator and reservation access required.'using errcode='42501';end if;
 select tenant_id into tenant from public.properties where id=p_property;
 owner_access:=private.is_tenant_admin(tenant);
 if p_page is null or p_page not between 1 and 10000 or length(coalesce(p_query,''))>100 then raise exception 'Check the guest search.'using errcode='22023';end if;
 with visible as(
  select g.*, (select count(*)from public.reservations r where r.guest_id=g.id and r.property_id=p_property)as bookings,
   (select count(*)from public.reservations r where r.guest_id=g.id and r.property_id=p_property and r.status in('confirmed','checked_in'))as active_bookings,
   exists(select 1 from public.conversations c where c.property_id=p_property and c.guest_id=g.id)
    or exists(select 1 from public.whatsapp_guest_authorizations a where a.property_id=p_property and a.guest_id=g.id)as linked,
   owner_access and private.guest_profile_unused(g.id)as can_delete
  from public.guests g where g.tenant_id=tenant
  and(exists(select 1 from public.reservations r where r.guest_id=g.id and r.property_id=p_property)
   or exists(select 1 from public.conversations c where c.guest_id=g.id and c.property_id=p_property)
   or exists(select 1 from public.whatsapp_guest_authorizations a where a.guest_id=g.id and a.property_id=p_property)
   or owner_access and private.guest_profile_unused(g.id))
  and strpos(lower(g.full_name||' '||coalesce(g.phone,'')||' '||coalesce(g.email,'')),lower(trim(coalesce(p_query,''))))>0
 ),rows as(select id,full_name,phone,email,bookings,active_bookings,linked,can_delete from visible order by full_name,id limit 20 offset(p_page-1)*20)
 select jsonb_build_object('total',(select count(*)from visible),'rows',coalesce((select jsonb_agg(to_jsonb(rows))from rows),'[]'::jsonb))into result;
 return result;
end $$;

create function public.manage_guest_identity(p_property uuid,p_guest uuid,p_action text,p_expected_phone text,p_confirm_name text,p_reason text)returns void
language plpgsql security definer set search_path=''as $$
declare g public.guests;p public.properties;phones text[];phone text;details jsonb;
begin
 if not private.has_permission(p_property,'staff.manage')or not private.has_permission(p_property,'reservations.write')then raise exception 'Hotel administrator and reservation access required.'using errcode='42501';end if;
 perform private.staff_share(p_property);
 select *into p from public.properties where id=p_property for update;
 select *into g from public.guests where id=p_guest and tenant_id=p.tenant_id for update;
 if g.id is null or not(exists(select 1 from public.reservations where property_id=p_property and guest_id=g.id)
  or exists(select 1 from public.conversations where property_id=p_property and guest_id=g.id)
  or exists(select 1 from public.whatsapp_guest_authorizations where property_id=p_property and guest_id=g.id)
  or private.is_tenant_admin(p.tenant_id)and private.guest_profile_unused(g.id))then raise exception 'Guest not found in this hotel.'using errcode='42501';end if;
 if p_action is null or p_action not in('reset','delete')or p_expected_phone is distinct from coalesce(g.phone,'')then raise exception 'Guest details changed. Refresh and review the profile.'using errcode='40001';end if;
 if trim(coalesce(p_confirm_name,''))<>g.full_name or length(trim(coalesce(p_reason,'')))not between 10 and 1000 then raise exception 'Type the guest’s full name and enter a reason of at least 10 characters.'using errcode='22023';end if;
 if p_action='delete'then
  if not private.is_tenant_admin(p.tenant_id)then raise exception 'Business owner or administrator access required to delete profiles.'using errcode='42501';end if;
  if not private.guest_profile_unused(g.id)then raise exception 'This profile has history. Keep the profile and use Reset WhatsApp link instead.'using errcode='22023';end if;
  begin
   delete from public.guests where id=g.id;
  exception when foreign_key_violation then raise exception 'This profile has linked records and cannot be deleted. Use Reset WhatsApp link instead.'using errcode='22023';end;
  insert into private.guest_identity_audit(property_id,guest_id,actor_id,action,reason,details)values(p.id,g.id,auth.uid(),'deleted_unused_profile',trim(p_reason),jsonb_build_object('name',g.full_name));
  return;
 end if;
 if exists(select 1 from public.reservations where property_id=p.id and guest_id=g.id and status in('confirmed','checked_in'))then raise exception 'Resolve this guest’s confirmed or in-house stays before resetting the WhatsApp link.'using errcode='22023';end if;
 perform 1 from public.conversations where property_id=p.id and guest_id=g.id order by id for update;
 -- Lock messages before checking in-flight delivery, so a queued item cannot be claimed during reset.
 perform 1 from public.messages where conversation_id in(select id from public.conversations where property_id=p.id and guest_id=g.id)order by id for update;
 if exists(select 1 from public.messages where conversation_id in(select id from public.conversations where property_id=p.id and guest_id=g.id)and direction='out'and(status='sending'or delivery_uncertain))then raise exception 'A message is sending or its delivery is uncertain. Resolve its delivery status before resetting.'using errcode='22023';end if;
 select array_agg(distinct value)into phones from(
  select wa_contact_id as value from public.conversations where property_id=p.id and guest_id=g.id
  union select wa_contact_id from public.whatsapp_guest_authorizations where property_id=p.id and guest_id=g.id
 )x;
 if phones is null then raise exception 'No WhatsApp link remains for this guest.'using errcode='22023';end if;
 if exists(select 1 from public.conversations where property_id=p.id and wa_contact_id=any(phones)and guest_id is not null and guest_id<>g.id)then raise exception 'The number now belongs to another profile. Refresh and review the guest records.'using errcode='40001';end if;
 select jsonb_build_object('name',g.full_name,'authorizations',coalesce((select jsonb_agg(to_jsonb(a))from public.whatsapp_guest_authorizations a where a.property_id=p.id and a.guest_id=g.id),'[]'::jsonb),'phones',phones)into details;
 foreach phone in array phones loop perform private.revoke_whatsapp_consent(p.id,phone,'both','staff_identity_reset');end loop;
 update public.messages set guest_identity_reset_at=clock_timestamp(),status=case when status='queued'then'failed'else status end,error=case when status='queued'then'Guest WhatsApp link was reset.'else error end
 where direction='out'and conversation_id in(select id from public.conversations where property_id=p.id and guest_id=g.id)and guest_identity_reset_at is null;
 update public.whatsapp_automation_events set state='skipped',reason='Guest WhatsApp link was reset.'where property_id=p.id and guest_id=g.id and state in('pending','blocked','queued');
 update public.whatsapp_campaign_recipients set state='skipped',skip_reason='Guest WhatsApp link was reset.'where property_id=p.id and wa_contact_id=any(phones)and state in('pending','queued');
 update public.guest_access_tokens set revoked_at=clock_timestamp()where property_id=p.id and revoked_at is null and reservation_id in(select id from public.reservations where property_id=p.id and guest_id=g.id);
 update private.whatsapp_journey_actions set expires_at=clock_timestamp()where conversation_id in(select id from public.conversations where property_id=p.id and guest_id=g.id)and consumed_at is null;
 update private.whatsapp_guest_inbound_jobs set state='done'where message_id in(select m.id from public.messages m join public.conversations c on c.id=m.conversation_id where c.property_id=p.id and c.guest_id=g.id)and state='pending';
 delete from private.whatsapp_booking_contacts where property_id=p.id and guest_id=g.id;
 delete from public.whatsapp_guest_authorizations where property_id=p.id and guest_id=g.id;
 update public.conversations set guest_id=null,contact_name=null,last_inbound_at=null,version=version+1 where property_id=p.id and guest_id=g.id;
 insert into private.guest_identity_audit(property_id,guest_id,actor_id,action,reason,details)values(p.id,g.id,auth.uid(),'reset_whatsapp_link',trim(p_reason),details);
end $$;
revoke all on function public.guest_identity_workspace(uuid,text,integer),public.manage_guest_identity(uuid,uuid,text,text,text,text)from public,anon;
grant execute on function public.guest_identity_workspace(uuid,text,integer),public.manage_guest_identity(uuid,uuid,text,text,text,text)to authenticated;
