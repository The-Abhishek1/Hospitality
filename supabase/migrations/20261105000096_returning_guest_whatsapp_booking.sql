-- Explicit profile selection preserves a returning guest's verified WhatsApp identity.
-- Never merge guest records simply because somebody enters the same phone number.
create function public.frontdesk_guest_choices(p_property uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $$
begin
 if not private.has_permission(p_property,'reservations.write')then raise exception 'Reservation access required.'using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x))from(select g.id,g.full_name,g.phone,g.email from public.guests g join public.reservations r on r.guest_id=g.id and r.property_id=p_property group by g.id order by max(r.created_at)desc,g.id limit 100)x),'[]'::jsonb);
end $$;
create function public.frontdesk_create_existing_guest(p_property uuid,p_currency text,p_request uuid,p_guest uuid,p_type uuid,p_in date,p_out date,p_adults integer,p_children integer,p_rate uuid default null,p_unit uuid default null,p_notes text default '',p_source text default 'direct',p_quote numeric default null,p_contact_permission boolean default false,p_contact_evidence text default '')returns uuid
language plpgsql security definer set search_path=''as $$
declare p public.properties;g public.guests;r uuid;u uuid;total numeric;d date;
begin
 if not private.has_permission(p_property,'reservations.write')then raise exception 'Reservation access required.'using errcode='42501';end if;
 if p_request is null then raise exception 'Reload the booking form.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_property::text||p_request::text,0));
 select *into p from public.properties where id=p_property for update;perform private.staff_share(p_property);
 select *into g from public.guests where id=p_guest and tenant_id=p.tenant_id and exists(select 1 from public.reservations where property_id=p_property and guest_id=p_guest);
 if g.id is null then raise exception 'Choose a returning guest from this hotel.'using errcode='42501';end if;
 if p_currency is distinct from p.currency then raise exception 'Hotel currency changed. Refresh and review the quote.'using errcode='40001';end if;
 select id into r from public.reservations where property_id=p_property and creation_request_id=p_request;
 if found then
  if not exists(select 1 from public.reservations where id=r and guest_id=g.id)then raise exception 'This booking request was already used for a different guest. Reload the form.'using errcode='40001';end if;
  return r;
 end if;
 d:=(now()at time zone p.timezone)::date;
 if p_in<d then raise exception 'New bookings cannot start in the past.'using errcode='22023';end if;
 if length(coalesce(p_notes,''))>2000 or p_source is null or p_source not in('direct','walk_in')then raise exception 'Check the booking source and notes.'using errcode='22023';end if;
 total:=private.frontdesk_price(p_property,p_type,p_in,p_out,p_adults,p_children,p_rate);
 if p_quote is null or p_quote<>total then raise exception 'The rate changed. Check availability again.'using errcode='22023';end if;
 insert into public.reservations(tenant_id,property_id,guest_id,source,check_in,check_out,adults,children,rate_plan_id,total_amount,currency,created_by,creation_request_id,notes)
 values(p.tenant_id,p.id,g.id,p_source,p_in,p_out,p_adults,p_children,p_rate,total,p.currency,auth.uid(),p_request,coalesce(p_notes,''))returning id into r;
 u:=private.frontdesk_allocate(p.id,p.tenant_id,p_type,p_in,p_out,r,p_unit);
 insert into public.reservation_events(tenant_id,property_id,reservation_id,event_type,actor_id,details)values(p.tenant_id,p.id,r,'created',auth.uid(),jsonb_build_object('unit_id',u,'source',p_source,'returning_guest',true));
 if p_contact_permission then perform public.record_whatsapp_booking_contact(p_property,r,p_contact_evidence,true);end if;
 return r;
end $$;
revoke all on function public.frontdesk_guest_choices(uuid),public.frontdesk_create_existing_guest(uuid,text,uuid,uuid,uuid,date,date,integer,integer,uuid,uuid,text,text,numeric,boolean,text)from public,anon;
grant execute on function public.frontdesk_guest_choices(uuid),public.frontdesk_create_existing_guest(uuid,text,uuid,uuid,uuid,date,date,integer,integer,uuid,uuid,text,text,numeric,boolean,text)to authenticated;
