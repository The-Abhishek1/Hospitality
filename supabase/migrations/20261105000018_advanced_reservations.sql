alter table public.reservations add column notes text not null default '' check(length(notes)<=2000),
  add column creation_request_id uuid, add column version integer not null default 1;
create unique index reservations_frontdesk_request on public.reservations(property_id,creation_request_id) where creation_request_id is not null;
create function private.reservation_version() returns trigger language plpgsql set search_path='' as $$
begin new.version:=old.version+1;return new;end $$;
revoke all on function private.reservation_version() from public,anon,authenticated;
create trigger reservations_version before update on public.reservations for each row execute function private.reservation_version();

-- One validator/pricer for new bookings and confirmed-stay changes.
create function private.frontdesk_price(p_property uuid,p_type uuid,p_in date,p_out date,p_adults int,p_children int,p_rate uuid) returns numeric
language plpgsql security definer set search_path='' as $$
declare t public.accommodation_types; a numeric:=0;
begin
 if p_in is null or p_out is null or p_out<=p_in or p_out-p_in>365 then raise exception 'Choose a stay of 1 to 365 nights.' using errcode='22023';end if;
 select * into t from public.accommodation_types where id=p_type and property_id=p_property;
 if not found then raise exception 'Room type not found.' using errcode='22023';end if;
 if p_adults is null or p_children is null or p_adults<1 or p_children<0 or p_adults+p_children>t.max_occupancy then raise exception 'Guest count exceeds the room type capacity.' using errcode='22023';end if;
 if p_rate is not null then
  select adjustment_percent into a from public.rate_plans where id=p_rate and property_id=p_property;
  if not found then raise exception 'Rate plan not found.' using errcode='22023';end if;
 end if;
 return round(t.base_rate*(p_out-p_in)*(1+a/100),2);
end $$;
revoke all on function private.frontdesk_price(uuid,uuid,date,date,int,int,uuid) from public,anon,authenticated;

create function private.frontdesk_allocate(p_property uuid,p_tenant uuid,p_type uuid,p_in date,p_out date,p_res uuid,p_unit uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare u uuid;
begin
 if p_unit is null then
  u:=private.allocate_unit(p_property,p_tenant,p_type,p_in,p_out,p_res);
  if u is null then raise exception 'No availability for those dates. Choose another room type or date range.' using errcode='P0002';end if;
  return u;
 end if;
 if not exists(select 1 from public.accommodation_units where id=p_unit and property_id=p_property and type_id=p_type and active) then
  raise exception 'Selected room is not active or does not match the room type.' using errcode='22023';end if;
 insert into public.unit_holds(tenant_id,property_id,unit_id,during,kind,reservation_id)
 values(p_tenant,p_property,p_unit,daterange(p_in,p_out,'[)'),'reservation',p_res);
 return p_unit;
end $$;
revoke all on function private.frontdesk_allocate(uuid,uuid,uuid,date,date,uuid,uuid) from public,anon,authenticated;

create function public.frontdesk_quote(p_property uuid,p_type uuid,p_in date,p_out date,p_adults int,p_children int,p_rate uuid default null,p_exclude uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare total numeric;r public.reservations;
begin
 if not private.has_permission(p_property,'reservations.write') then raise exception 'not permitted' using errcode='42501';end if;
 if p_exclude is not null then select * into r from public.reservations where id=p_exclude and property_id=p_property;
  if not found or not private.has_permission(r.property_id,'reservations.read') then raise exception 'not permitted' using errcode='42501';end if;end if;
 total:=private.frontdesk_price(p_property,p_type,p_in,p_out,p_adults,p_children,p_rate);
 return jsonb_build_object('total',total,'nights',p_out-p_in,'rooms',coalesce((select jsonb_agg(jsonb_build_object('id',u.id,'name',u.name,'housekeeping_status',u.housekeeping_status) order by u.name)
 from public.accommodation_units u where u.property_id=p_property and u.type_id=p_type and u.active and not exists(
 select 1 from public.unit_holds h where h.unit_id=u.id and h.active and (p_exclude is null or h.reservation_id is distinct from p_exclude) and h.during&&daterange(p_in,p_out,'[)'))),'[]'::jsonb));
end $$;

create function public.frontdesk_create(p_property uuid,p_request uuid,p_guest_name text,p_phone text,p_email text,p_type uuid,p_in date,p_out date,p_adults int,p_children int,p_rate uuid default null,p_unit uuid default null,p_notes text default '',p_source text default 'direct',p_quote numeric default null) returns uuid
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

create function public.frontdesk_update(p_id uuid,p_version int,p_type uuid,p_in date,p_out date,p_adults int,p_children int,p_rate uuid default null,p_unit uuid default null,p_quote numeric default null) returns void
language plpgsql security definer set search_path='' as $$
declare r public.reservations;total numeric;u uuid;d date;
begin
 r:=private.lock_reservation(p_id,'reservations.write');
 if r.version is distinct from p_version then raise exception 'This reservation changed. Refresh before saving.' using errcode='40001';end if;
 if r.status<>'confirmed' or r.source='ota' then raise exception 'Only confirmed direct or walk-in stays can be edited here. Change channel bookings through the channel.' using errcode='22023';end if;
 if exists(select 1 from public.folios f where f.reservation_id=r.id and (f.status='closed' or exists(select 1 from public.folio_items where folio_id=f.id) or exists(select 1 from public.payments where folio_id=f.id))) then raise exception 'This stay has financial activity. Resolve its billing before changing dates or rates.' using errcode='22023';end if;
 select (now() at time zone timezone)::date into d from public.properties where id=r.property_id;
 if p_in<d then raise exception 'Updated arrivals cannot be in the past.' using errcode='22023';end if;
 total:=private.frontdesk_price(r.property_id,p_type,p_in,p_out,p_adults,p_children,p_rate);
 if p_quote is null or p_quote<>total then raise exception 'The rate changed. Check availability again.' using errcode='22023';end if;
 update public.unit_holds set active=false where reservation_id=r.id and active;
 u:=private.frontdesk_allocate(r.property_id,r.tenant_id,p_type,p_in,p_out,r.id,p_unit);
 update public.reservations set check_in=p_in,check_out=p_out,adults=p_adults,children=p_children,rate_plan_id=p_rate,total_amount=total where id=r.id;
 insert into public.reservation_events(tenant_id,property_id,reservation_id,event_type,actor_id,details)
 values(r.tenant_id,r.property_id,r.id,'stay_updated',auth.uid(),jsonb_build_object('previous_check_in',r.check_in,'previous_check_out',r.check_out,'previous_total',r.total_amount,'check_in',p_in,'check_out',p_out,'total',total,'unit_id',u));
end $$;

create function public.frontdesk_move(p_id uuid,p_version int,p_unit uuid,p_reason text) returns void
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

create function public.frontdesk_action(p_id uuid,p_version int,p_action text,p_reason text default '') returns void
language plpgsql security definer set search_path='' as $$
declare r public.reservations;d date;u public.accommodation_units;
begin
 if p_action not in ('check_in','check_out','cancel','no_show','notes','post_charges') or p_action is null then raise exception 'Unknown reservation action.' using errcode='22023';end if;
 r:=private.lock_reservation(p_id,case when p_action in ('check_in','check_out') then 'frontdesk.manage' when p_action='post_charges' then 'billing.manage' else 'reservations.write' end);
 if r.version is distinct from p_version then raise exception 'This reservation changed. Refresh before continuing.' using errcode='40001';end if;
 select (now() at time zone timezone)::date into d from public.properties where id=r.property_id;
 if p_action='check_in' then
  if d<r.check_in or d>=r.check_out then raise exception 'Check-in is only available during the booked stay. Update the stay dates first.' using errcode='22023';end if;
  select u1.* into u from public.unit_holds h join public.accommodation_units u1 on u1.id=h.unit_id where h.reservation_id=r.id and h.active for update of u1;
  if not found or not u.active or u.housekeeping_status<>'clean' then raise exception 'The assigned room must be active and clean before check-in.' using errcode='22023';end if;
  if exists(select 1 from public.unit_holds h join public.reservations other on other.id=h.reservation_id where h.unit_id=u.id and h.active and other.id<>r.id and other.status='checked_in') then raise exception 'Another guest is still checked into this room.' using errcode='22023';end if;
  perform public.check_in_reservation(r.id);return;
 elsif p_action='check_out' then
  perform public.check_out_reservation(r.id);return;
 elsif p_action='post_charges' then
  perform public.post_room_charges(r.id);return;
 elsif p_action='notes' then
  if length(coalesce(p_reason,''))>2000 then raise exception 'Notes must be 2000 characters or fewer.' using errcode='22023';end if;
  update public.reservations set notes=coalesce(p_reason,'') where id=r.id;
 elsif p_action='cancel' then
  if length(trim(coalesce(p_reason,''))) not between 3 and 500 then raise exception 'Enter a cancellation reason (3–500 characters).' using errcode='22023';end if;
  if r.source='ota' then raise exception 'Cancel channel bookings through the channel to keep both systems aligned.' using errcode='22023';end if;
  perform public.cancel_reservation(r.id,trim(p_reason));return;
 elsif p_action='no_show' then
  if r.status<>'confirmed' or d<r.check_in then raise exception 'Only an arrival due today or earlier can be marked no-show.' using errcode='22023';end if;
  if length(trim(coalesce(p_reason,''))) not between 3 and 500 then raise exception 'Enter a no-show reason (3–500 characters).' using errcode='22023';end if;
  update public.reservations set status='no_show' where id=r.id;
  update public.unit_holds set active=false where reservation_id=r.id and active;
 end if;
 insert into public.reservation_events(tenant_id,property_id,reservation_id,event_type,actor_id,details)
 values(r.tenant_id,r.property_id,r.id,case when p_action='notes' then 'notes_updated' else 'no_show' end,auth.uid(),case when p_action='notes' then '{}'::jsonb else jsonb_build_object('reason',trim(p_reason)) end);
end $$;

-- Paginated, searchable read model. Invoker rights keep all existing RLS policies.
create function public.reservation_workspace(p_property uuid,p_filters jsonb default '{}') returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare p public.properties;d date;start_day date;page int;room_page int;result jsonb;q text;v_status text;v_source text;v_view text;date_from date;date_to date;
begin
 if not private.has_permission(p_property,'reservations.read') then raise exception 'not permitted' using errcode='42501';end if;
 select * into p from public.properties where id=p_property;d:=(now() at time zone p.timezone)::date;
 start_day:=coalesce((p_filters->>'start')::date,d);page:=greatest(1,least(100000,coalesce((p_filters->>'page')::int,1)));room_page:=greatest(1,least(100000,coalesce((p_filters->>'room_page')::int,1)));
 q:=left(trim(coalesce(p_filters->>'q','')),100);v_status:=p_filters->>'status';v_source:=p_filters->>'source';v_view:=coalesce(p_filters->>'view','upcoming');date_from:=nullif(p_filters->>'from','')::date;date_to:=nullif(p_filters->>'to','')::date;
 with filtered as materialized (
  select r.id,r.version,r.guest_id,r.status,r.source,r.check_in,r.check_out,r.adults,r.children,r.total_amount,r.currency,r.created_at,g.full_name,g.phone,room.name as room,room.type_name
  from public.reservations r left join public.guests g on g.id=r.guest_id
  left join lateral(select u.name,t.name as type_name from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id join public.accommodation_types t on t.id=u.type_id where h.reservation_id=r.id order by h.active desc,h.created_at desc limit 1) room on true
  where r.property_id=p_property
   and (q='' or strpos(lower(concat_ws(' ',g.full_name,g.phone,g.email,r.id::text,r.channel_ref)),lower(q))>0)
   and (coalesce(v_status,'')='' or r.status=v_status) and(coalesce(v_source,'')='' or r.source=v_source)
   and (date_from is null or r.check_out>date_from) and(date_to is null or r.check_in<=date_to)
   and(case v_view when 'arrivals' then r.check_in=d and r.status in ('confirmed','checked_in','checked_out') when 'departures' then r.check_out=d and r.status in ('checked_in','checked_out') when 'in_house' then r.status='checked_in' when 'upcoming' then r.status in ('confirmed','checked_in') else true end)
 ) select jsonb_build_object('total',(select count(*) from filtered),'page',page,'rows',coalesce((select jsonb_agg(to_jsonb(x)) from(select * from filtered order by check_in,id limit 20 offset (page-1)*20)x),'[]'::jsonb)) into result;
 result:=result||jsonb_build_object('day',d,'start',start_day,'can_write',private.has_permission(p_property,'reservations.write'),'can_frontdesk',private.has_permission(p_property,'frontdesk.manage'),
  'stats',(select jsonb_build_object('arrivals',count(*) filter(where check_in=d and status='confirmed'),'departures',count(*) filter(where check_out=d and status='checked_in'),'in_house',count(*) filter(where status='checked_in'),'upcoming',count(*) filter(where status='confirmed' and check_in>=d)) from public.reservations where property_id=p_property),
  'room_total',(select count(*) from public.accommodation_units where property_id=p_property and active),
  'room_page',room_page,
  'calendar',coalesce((select jsonb_agg(to_jsonb(x)) from(
   select u.id,u.name,u.type_id,t.name as type_name,u.housekeeping_status,coalesce((select jsonb_agg(jsonb_build_object('id',h.id,'during',h.during::text,'kind',h.kind,'reservation_id',h.reservation_id,'guest',g.full_name,'status',r.status,'reason',h.reason)) from public.unit_holds h left join public.reservations r on r.id=h.reservation_id left join public.guests g on g.id=r.guest_id where h.unit_id=u.id and h.active and h.during&&daterange(start_day,start_day+14,'[)')),'[]'::jsonb) as holds
   from public.accommodation_units u join public.accommodation_types t on t.id=u.type_id where u.property_id=p_property and u.active order by u.name,u.id limit 12 offset(room_page-1)*12)x),'[]'::jsonb));
 return result;
end $$;

create function public.reservation_detail(p_property uuid,p_id uuid) returns jsonb
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
  result:=result||jsonb_build_object('finance',jsonb_build_object('folio_id',f.id,'folio_status',f.status,'posted',posted,'paid',paid,'refunded',refunded,'balance',posted-paid+refunded,'unposted_room',greatest(0,r.total_amount-room_posted),'checkout_balance',posted-paid+refunded+greatest(0,r.total_amount-room_posted)));
 end if;
 return result;
end $$;

revoke all on function public.frontdesk_quote(uuid,uuid,date,date,int,int,uuid,uuid),public.frontdesk_create(uuid,uuid,text,text,text,uuid,date,date,int,int,uuid,uuid,text,text,numeric),public.frontdesk_update(uuid,int,uuid,date,date,int,int,uuid,uuid,numeric),public.frontdesk_move(uuid,int,uuid,text),public.frontdesk_action(uuid,int,text,text),public.reservation_workspace(uuid,jsonb),public.reservation_detail(uuid,uuid) from public,anon;
grant execute on function public.frontdesk_quote(uuid,uuid,date,date,int,int,uuid,uuid),public.frontdesk_create(uuid,uuid,text,text,text,uuid,date,date,int,int,uuid,uuid,text,text,numeric),public.frontdesk_update(uuid,int,uuid,date,date,int,int,uuid,uuid,numeric),public.frontdesk_move(uuid,int,uuid,text),public.frontdesk_action(uuid,int,text,text),public.reservation_workspace(uuid,jsonb),public.reservation_detail(uuid,uuid) to authenticated;

create or replace function public.workspace_permissions(p_property uuid) returns jsonb
language plpgsql stable security invoker set search_path = '' as $$
begin
  if not private.has_property_access(p_property) then raise exception 'property not accessible' using errcode = '42501'; end if;
  return jsonb_build_object(
    'reservations',private.has_permission(p_property,'reservations.read'),
    'channels',private.has_permission(p_property,'staff.manage'),
    'inbox',private.has_permission(p_property,'whatsapp.use'),
    'finance',private.has_permission(p_property,'finance.read') or private.has_permission(p_property,'billing.manage'),
    'requests',private.has_permission(p_property,'guest_requests.read'),
    'tasks',private.has_permission(p_property,'tasks.read'),
    'inventory',private.has_permission(p_property,'inventory.manage'),
    'orders',private.has_permission(p_property,'orders.read'),
    'book',private.has_permission(p_property,'reservations.write'),
    'frontdesk',private.has_permission(p_property,'frontdesk.manage'));
end $$;
