-- Make missing configuration and actual delivery state visible beside the booking.
create function public.booking_welcome_status(p_property uuid,p_reservation uuid default null)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare r public.reservations;rule public.whatsapp_automation_rules;t public.message_templates;e public.whatsapp_automation_events;m public.messages;state text:='ready';why text;permission boolean;journey boolean;
begin
 if not private.has_permission(p_property,'reservations.read')then raise exception 'Reservation access required.'using errcode='42501';end if;
 if p_reservation is not null then select *into r from public.reservations where id=p_reservation and property_id=p_property;if r.id is null then raise exception 'Reservation not found.'using errcode='P0002';end if;end if;
 select enabled into journey from public.whatsapp_journey_settings where property_id=p_property;
 select *into rule from public.whatsapp_automation_rules where property_id=p_property and event_key='booking_confirmed';select *into t from public.message_templates where id=rule.template_id and property_id=p_property;
 if p_reservation is not null then
  select *into e from public.whatsapp_automation_events where property_id=p_property and reservation_id=p_reservation and event_key='booking_confirmed'order by created_at desc limit 1;
  select *into m from public.messages where id=e.message_id;
  permission:=exists(select 1 from private.whatsapp_booking_contacts where reservation_id=r.id and property_id=p_property and guest_id=r.guest_id);
 end if;
 if m.status in('sent','delivered','read')then state:=m.status;why:='Booking welcome sent.';
 elsif m.status='sending'then state:='sending';why:='Booking welcome is being sent.';
 elsif m.status='failed'then state:='failed';why:=coalesce(m.error,'Delivery failed. Review WhatsApp delivery history.');
 elsif coalesce(journey,false)is not true then state:='off';why:='Enable the WhatsApp guest journey for this hotel.';
 elsif coalesce(rule.enabled,false)is not true then state:='off';why:='Booking welcome is off. Assign an approved template and activate this event.';
 elsif t.id is null then state:='template';why:='No booking-welcome template is assigned.';
 elsif not(rule.parameter_keys?'portal_url')then state:='template';why:='Choose a welcome template containing the personal guest-task link.';
 elsif not exists(select 1 from public.whatsapp_connections where property_id=p_property and status='active')then state:='connection';why:='Connect this hotel’s WhatsApp number.';
 elsif t.status<>'approved'or not t.automation_supported or t.provider_checked_at<now()-interval '24 hours'then state:='template';why:='Sync and choose a compatible approved template.';
 elsif p_reservation is not null and not permission then state:='permission';why:='Record the guest’s prior permission for this one booking welcome.';
 elsif e.id is not null then
  why:=private.whatsapp_automation_error(e.id);
  if why is not null then state:='blocked';elsif m.status='queued'then state:='queued';why:='Queued for automatic WhatsApp delivery.';else state:=e.state;why:=coalesce(e.reason,'Booking welcome is waiting for delivery.');end if;
 elsif p_reservation is not null then state:='not_queued';why:='Welcome is configured, but no message was queued for this booking. Send its welcome once below.';
 else why:='Ready: a booking welcome with the document link is queued automatically when prior contact permission is recorded.';
 end if;
 return jsonb_build_object('state',state,'reason',why,'template',t.name,'permission_recorded',permission,'can_configure',private.has_permission(p_property,'staff.manage'),'can_send',private.has_permission(p_property,'reservations.write')and r.status='confirmed'and permission and state in('not_queued','blocked','pending')and r.created_at>now()-interval '24 hours','event_id',e.id,'message_id',m.id);
end $$;
create function public.request_booking_welcome(p_property uuid,p_reservation uuid)returns jsonb
language plpgsql security definer set search_path=''as $$
declare r public.reservations;rule public.whatsapp_automation_rules;e public.whatsapp_automation_events;status jsonb;why text;
begin
 if not private.has_permission(p_property,'reservations.write')then raise exception 'Reservation write access required.'using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('booking-welcome:'||p_reservation::text,0));perform private.staff_share(p_property);
 select *into r from public.reservations where id=p_reservation and property_id=p_property for update;
 if r.id is null then raise exception 'Reservation not found.'using errcode='P0002';end if;
 status:=public.booking_welcome_status(p_property,p_reservation);
 if status->>'state'in('sent','delivered','read','sending','queued')then return status;end if;
 if r.status<>'confirmed'or r.created_at<now()-interval '24 hours'then raise exception 'Only a recent confirmed booking can request its initial welcome here.'using errcode='22023';end if;
 if not coalesce((status->>'can_send')::boolean,false)then raise exception '%',status->>'reason'using errcode='22023';end if;
 select *into rule from public.whatsapp_automation_rules where property_id=p_property and event_key='booking_confirmed';
 perform private.capture_whatsapp_event(p_property,r.id,'booking_confirmed','reservations:'||r.id::text||':booking_confirmed','reservations',r.id,'confirmed','{}');
 select *into e from public.whatsapp_automation_events where property_id=p_property and reservation_id=r.id and event_key='booking_confirmed'order by created_at desc limit 1;
 if e.id is null then raise exception 'Activate the booking-welcome rule first.'using errcode='22023';end if;
 if e.state='skipped'or e.expires_at<=now()then raise exception 'This welcome expired. Review the booking and contact reception.'using errcode='22023';end if;
 why:=private.whatsapp_automation_error(e.id);
 update public.whatsapp_automation_events set next_check_at=now(),reason=why,state=case when why is null then'pending'else'blocked'end where id=e.id and state in('pending','blocked');
 insert into public.whatsapp_automation_audit(property_id,tenant_id,actor,action,details)values(p_property,r.tenant_id,auth.uid(),'booking_welcome_requested',jsonb_build_object('reservation',r.id,'event',e.id));
 if why is null then perform private.wake_whatsapp_guest_worker();end if;
 return public.booking_welcome_status(p_property,p_reservation);
end $$;
revoke all on function public.booking_welcome_status(uuid,uuid),public.request_booking_welcome(uuid,uuid)from public,anon;
grant execute on function public.booking_welcome_status(uuid,uuid),public.request_booking_welcome(uuid,uuid)to authenticated;
