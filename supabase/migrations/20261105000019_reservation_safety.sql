-- Additional validation and settlement display rules for the front desk.
create or replace function public.frontdesk_create(p_property uuid,p_request uuid,p_guest_name text,p_phone text,p_email text,p_type uuid,p_in date,p_out date,p_adults int,p_children int,p_rate uuid default null,p_unit uuid default null,p_notes text default '',p_source text default 'direct',p_quote numeric default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare p public.properties;r uuid;g uuid;u uuid;total numeric;d date;
begin
 if not private.has_permission(p_property,'reservations.write') then raise exception 'not permitted' using errcode='42501';end if;
 if p_request is null then raise exception 'Reload the booking form and try again.' using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_property::text||p_request::text,0));
 select id into r from public.reservations where property_id=p_property and creation_request_id=p_request;
 if found then return r;end if;
 select * into p from public.properties where id=p_property for share;
 d:=(now() at time zone p.timezone)::date;
 if p_in<d then raise exception 'New bookings cannot start in the past.' using errcode='22023';end if;
 if p_guest_name is null or length(trim(p_guest_name)) not between 2 and 120 or length(coalesce(p_phone,''))>40 or length(coalesce(p_email,''))>254 or length(coalesce(p_notes,''))>2000 then raise exception 'Check the guest details and notes.' using errcode='22023';end if;
 if nullif(trim(coalesce(p_email,'')),'') is not null and p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'Enter a valid guest email.' using errcode='22023';end if;
 if p_source is null or p_source not in ('direct','walk_in') then raise exception 'Choose direct or walk-in for a front desk booking.' using errcode='22023';end if;
 total:=private.frontdesk_price(p_property,p_type,p_in,p_out,p_adults,p_children,p_rate);
 if p_quote is null or p_quote<>total then raise exception 'The rate changed. Check availability again before booking.' using errcode='22023';end if;
 insert into public.guests(tenant_id,full_name,phone,email) values(p.tenant_id,trim(p_guest_name),nullif(trim(p_phone),''),nullif(trim(p_email),'')) returning id into g;
 insert into public.reservations(tenant_id,property_id,guest_id,source,check_in,check_out,adults,children,rate_plan_id,total_amount,currency,created_by,creation_request_id,notes)
 values(p.tenant_id,p.id,g,p_source,p_in,p_out,p_adults,p_children,p_rate,total,p.currency,auth.uid(),p_request,coalesce(p_notes,'')) returning id into r;
 u:=private.frontdesk_allocate(p.id,p.tenant_id,p_type,p_in,p_out,r,p_unit);
 insert into public.reservation_events(tenant_id,property_id,reservation_id,event_type,actor_id,details)
 values(p.tenant_id,p.id,r,'created',auth.uid(),jsonb_build_object('unit_id',u,'source',p_source));
 return r;
end $$;

create or replace function public.frontdesk_move(p_id uuid,p_version int,p_unit uuid,p_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare r public.reservations;old_unit public.accommodation_units;target public.accommodation_units;u uuid;
begin
 r:=private.lock_reservation(p_id,'frontdesk.manage');
 if r.version is distinct from p_version then raise exception 'This reservation changed. Refresh before moving rooms.' using errcode='40001';end if;
 if r.status not in ('confirmed','checked_in') then raise exception 'This stay cannot be moved.' using errcode='22023';end if;
 if p_reason is null or length(trim(p_reason)) not between 3 and 500 then raise exception 'Enter a room-move reason (3–500 characters).' using errcode='22023';end if;
 select u1.* into old_unit from public.unit_holds h join public.accommodation_units u1 on u1.id=h.unit_id where h.reservation_id=r.id and h.active limit 1;
 select * into target from public.accommodation_units where id=p_unit and property_id=r.property_id and active for update;
 if not found or target.type_id is distinct from old_unit.type_id or target.id=old_unit.id then raise exception 'Choose a different active room of the same type.' using errcode='22023';end if;
 if r.status='checked_in' and target.housekeeping_status<>'clean' then raise exception 'The destination room must be clean.' using errcode='22023';end if;
 if r.status='checked_in' and exists(select 1 from public.unit_holds h join public.reservations other on other.id=h.reservation_id where h.unit_id=target.id and h.active and other.id<>r.id and other.status='checked_in') then raise exception 'Another guest is still checked into the destination room.' using errcode='22023';end if;
 update public.unit_holds set active=false where reservation_id=r.id and active;
 u:=private.frontdesk_allocate(r.property_id,r.tenant_id,target.type_id,r.check_in,r.check_out,r.id,p_unit);
 if r.status='checked_in' then
  update public.accommodation_units set housekeeping_status='dirty' where id=old_unit.id;
  insert into public.tasks(tenant_id,property_id,title,kind,unit_id,reservation_id,created_by)
  values(r.tenant_id,r.property_id,'Clean unit '||old_unit.name,'housekeeping',old_unit.id,r.id,auth.uid())
  on conflict (unit_id) where kind='housekeeping' and status in ('open','in_progress') do nothing;
 end if;
 update public.reservations set notes=notes where id=r.id;
 insert into public.reservation_events(tenant_id,property_id,reservation_id,event_type,actor_id,details)
 values(r.tenant_id,r.property_id,r.id,'room_moved',auth.uid(),jsonb_build_object('from_room',old_unit.name,'to_room',target.name,'reason',trim(p_reason)));
end $$;

create or replace function public.reservation_detail(p_property uuid,p_id uuid) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare r public.reservations;result jsonb;can_fin boolean;f public.folios;posted numeric;paid numeric;refunded numeric;room_posted numeric;
begin
 if not private.has_permission(p_property,'reservations.read') then raise exception 'not permitted' using errcode='42501';end if;
 select * into r from public.reservations where id=p_id and property_id=p_property;
 if not found then raise exception 'Reservation not found.' using errcode='P0002';end if;
 can_fin:=private.has_permission(p_property,'finance.read') or private.has_permission(p_property,'billing.manage');
 result:=jsonb_build_object('stay',to_jsonb(r),'guest',(select to_jsonb(g) from public.guests g where id=r.guest_id),
 'room',(select jsonb_build_object('id',u.id,'name',u.name,'type_id',u.type_id,'type_name',t.name,'housekeeping_status',u.housekeeping_status,'active',u.active) from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id join public.accommodation_types t on t.id=u.type_id where h.reservation_id=r.id order by h.active desc,h.created_at desc limit 1),
 'events',coalesce((select jsonb_agg(to_jsonb(x)) from(select event_type,created_at,details from public.reservation_events where reservation_id=r.id order by created_at desc,id desc limit 30)x),'[]'::jsonb),
 'can_write',private.has_permission(p_property,'reservations.write'),'can_frontdesk',private.has_permission(p_property,'frontdesk.manage'),
 'can_bill',private.has_permission(p_property,'billing.manage'),'can_finance',can_fin,'can_portal',private.has_permission(p_property,'guest_requests.manage'));
 if can_fin then
  select * into f from public.folios where reservation_id=r.id;
  select coalesce(sum(amount),0),coalesce(sum(amount) filter(where kind='room'),0) into posted,room_posted from public.folio_items where folio_id=f.id;
  select coalesce(sum(amount),0) into paid from public.payments where folio_id=f.id;
  select coalesce(sum(rf.amount),0) into refunded from public.refunds rf join public.payments py on py.id=rf.payment_id where py.folio_id=f.id;
  result:=result||jsonb_build_object('finance',jsonb_build_object('folio_id',f.id,'folio_status',f.status,'posted',posted,'paid',paid,'refunded',refunded,'balance',posted-paid+refunded,'unposted_room',case when r.status in ('confirmed','checked_in') then greatest(0,r.total_amount-room_posted) else 0 end,'checkout_balance',posted-paid+refunded+case when r.status in ('confirmed','checked_in') then greatest(0,r.total_amount-room_posted) else 0 end));
 end if;
 return result;
end $$;
