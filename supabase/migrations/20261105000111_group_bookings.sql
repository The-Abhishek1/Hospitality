-- A group contains normal room reservations; existing admission, billing and messaging guards apply.
create table public.reservation_groups(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references public.tenants(id)on delete cascade,
 property_id uuid not null references public.properties(id)on delete cascade,creation_request_id uuid not null,
 name text not null check(length(name)between 2 and 120),mode text not null check(mode in('reservation','walk_in')),
 check_in date not null,check_out date not null,room_count integer not null check(room_count between 2 and 50),
 notes text not null default '',request_hash text not null,initial_results jsonb not null default '[]',
 created_by uuid references public.profiles(id),created_at timestamptz not null default now(),unique(property_id,creation_request_id)
);
create index reservation_groups_directory on public.reservation_groups(property_id,created_at desc,id);
alter table public.reservation_groups enable row level security;
revoke all on public.reservation_groups from public,anon,authenticated;
grant select on public.reservation_groups to authenticated;
grant all on public.reservation_groups to service_role;
create policy reservation_groups_read on public.reservation_groups for select to authenticated using(private.has_permission(property_id,'reservations.read'));
alter table public.reservations add column group_id uuid references public.reservation_groups(id)on delete set null;
create index reservations_group on public.reservations(group_id)where group_id is not null;
create function private.check_reservation_group()returns trigger language plpgsql security definer set search_path=''as $$
begin
 if new.group_id is not null and not exists(select 1 from public.reservation_groups where id=new.group_id and property_id=new.property_id and tenant_id=new.tenant_id)then raise exception 'The group must belong to this reservation’s hotel.'using errcode='22023';end if;
 return new;
end $$;
revoke all on function private.check_reservation_group()from public,anon,authenticated;
create trigger reservation_group_scope before insert or update of group_id,property_id,tenant_id on public.reservations for each row execute function private.check_reservation_group();

create function public.frontdesk_group_quote(p_property uuid,p_in date,p_out date,p_items jsonb,p_mode text default 'reservation')returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare item jsonb;q jsonb;room jsonb;chosen uuid[]:='{}';requested uuid[];result jsonb:='[]';n integer:=0;amount numeric:=0;today date;
begin
 if not private.has_permission(p_property,'reservations.write')then raise exception 'Booking permission required.'using errcode='42501';end if;
 if p_mode is null or p_mode not in('reservation','walk_in')then raise exception 'Choose reservation or walk-in.'using errcode='22023';end if;
 if p_mode='walk_in'and not private.has_permission(p_property,'frontdesk.manage')then raise exception 'Front desk access is required for walk-ins.'using errcode='42501';end if;
 if p_items is null or jsonb_typeof(p_items)<>'array'or jsonb_array_length(p_items)not between 2 and 50 or length(p_items::text)>200000 then raise exception 'Add between 2 and 50 rooms.'using errcode='22023';end if;
 select(now()at time zone timezone)::date into today from public.properties where id=p_property;
 if p_in is null or p_out is null or p_in<today or p_out-p_in not between 1 and 365 or(p_mode='walk_in'and p_in<>today)then raise exception 'Choose valid stay dates. Walk-ins must arrive today in hotel time.'using errcode='22023';end if;
 select coalesce(array_agg((x->>'unit_id')::uuid),'{}')into requested from jsonb_array_elements(p_items)x where nullif(x->>'unit_id','')is not null;
 if cardinality(requested)<>(select count(distinct x)from unnest(requested)x)then raise exception 'A room can only be assigned once in this group.'using errcode='22023';end if;
 for item in select *from jsonb_array_elements(p_items)loop
  n:=n+1;
  if jsonb_typeof(item)<>'object'or nullif(item->>'type_id','')is null or nullif(item->>'adults','')is null or nullif(item->>'children','')is null then raise exception 'Complete the room type and guest counts for every room.'using errcode='22023';end if;
  q:=public.frontdesk_quote(p_property,(item->>'type_id')::uuid,p_in,p_out,(item->>'adults')::integer,(item->>'children')::integer,nullif(item->>'rate_id','')::uuid);
  select x into room from jsonb_array_elements(q->'rooms')x
   where not((x->>'id')::uuid=any(chosen))and(p_mode<>'walk_in'or not exists(select 1 from public.unit_holds held join public.reservations staying on staying.id=held.reservation_id where held.unit_id=(x->>'id')::uuid and held.active and staying.status='checked_in'))and(case when nullif(item->>'unit_id','')is not null then x->>'id'=item->>'unit_id'else not((x->>'id')::uuid=any(requested))end)
   order by case when p_mode='walk_in'and x->>'housekeeping_status'='clean'then 0 else 1 end,x->>'name',x->>'id'limit 1;
  if room is null then raise exception 'Room % has no matching availability. Choose another type or dates, or reduce the group.',n using errcode='22023';end if;
  chosen:=array_append(chosen,(room->>'id')::uuid);amount:=amount+(q->>'total')::numeric;
  result:=result||jsonb_build_array(jsonb_build_object('unit_id',room->>'id','room',room->>'name','housekeeping_status',room->>'housekeeping_status','quote',(q->>'total')::numeric));
 end loop;
 return jsonb_build_object('rows',result,'total',amount,'nights',p_out-p_in);
exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'Check the room types, assignments and guest counts.'using errcode='22023';
end $$;
revoke all on function public.frontdesk_group_quote(uuid,date,date,jsonb,text)from public,anon;
grant execute on function public.frontdesk_group_quote(uuid,date,date,jsonb,text)to authenticated;

create function public.frontdesk_group_create(p_property uuid,p_currency text,p_request uuid,p_name text,p_mode text,p_in date,p_out date,p_items jsonb,p_notes text default '')returns uuid
language plpgsql security definer set search_path=''as $$
declare hotel public.properties;existing public.reservation_groups;payload jsonb;group_key uuid;item jsonb;preview jsonb;result jsonb;results jsonb:='[]';rid uuid;first_guest uuid;guest uuid;child uuid;n integer:=0;notes text;
begin
 perform private.staff_share(p_property);
 if not private.has_permission(p_property,'reservations.write')then raise exception 'Booking permission required.'using errcode='42501';end if;
 if p_mode='walk_in'and not private.has_permission(p_property,'frontdesk.manage')then raise exception 'Front desk access is required for walk-ins.'using errcode='42501';end if;
 if p_request is null or p_name is null or length(trim(p_name))not between 2 and 120 or length(coalesce(p_notes,''))>1400 then raise exception 'Enter a group name (2–120 characters) and notes up to 1400 characters.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_property::text||p_request::text,0));
 select *into hotel from public.properties where id=p_property for update;
 if p_currency is distinct from hotel.currency then raise exception 'Hotel currency changed. Refresh the group quote.'using errcode='40001';end if;
 payload:=jsonb_build_object('name',trim(p_name),'mode',p_mode,'check_in',p_in,'check_out',p_out,'items',p_items,'notes',coalesce(p_notes,''),'currency',p_currency);
 select *into existing from public.reservation_groups where property_id=p_property and creation_request_id=p_request;
 if found then
  if existing.request_hash is distinct from encode(sha256(convert_to(payload::text,'UTF8')),'hex') then raise exception 'This group request was already used with different details. Reload the form.'using errcode='40001';end if;
  return existing.id;
 end if;
 preview:=public.frontdesk_group_quote(p_property,p_in,p_out,p_items,p_mode);
 insert into public.reservation_groups(tenant_id,property_id,creation_request_id,name,mode,check_in,check_out,room_count,notes,request_hash,created_by)
 values(hotel.tenant_id,p_property,p_request,trim(p_name),p_mode,p_in,p_out,jsonb_array_length(p_items),coalesce(p_notes,''),encode(sha256(convert_to(payload::text,'UTF8')),'hex'),auth.uid())returning id into group_key;
 notes:='Group: '||trim(p_name)||case when nullif(trim(p_notes),'')is not null then E'\n'||trim(p_notes)else ''end;
 for item in select *from jsonb_array_elements(p_items)loop
  if nullif(item->>'unit_id','')is null or(item->>'quote')::numeric is distinct from(preview->'rows'->n->>'quote')::numeric then raise exception 'Check group availability and review the latest room prices before confirming.'using errcode='22023';end if;
  if coalesce((item->>'same_guest')::boolean,false)then
   if n=0 then raise exception 'Choose the lead guest in the first room.'using errcode='22023';end if;
   guest:=first_guest;
   if coalesce((item->>'contact_permission')::boolean,false)then raise exception 'Record each room’s contact permission separately with its own guest.'using errcode='22023';end if;
  else guest:=nullif(item->>'guest_id','')::uuid;end if;
  child:=gen_random_uuid();
  if p_mode='walk_in'then
   result:=public.frontdesk_walk_in(p_property,p_currency,child,guest,item->>'name',item->>'phone',item->>'email',(item->>'type_id')::uuid,p_in,p_out,(item->>'adults')::integer,(item->>'children')::integer,nullif(item->>'rate_id','')::uuid,(item->>'unit_id')::uuid,notes,(item->>'quote')::numeric,coalesce((item->>'contact_permission')::boolean,false),coalesce(item->>'contact_evidence',''));
   rid:=(result->>'id')::uuid;
  else
   if guest is null then rid:=public.frontdesk_create_whatsapp(p_property,p_currency,child,item->>'name',item->>'phone',item->>'email',(item->>'type_id')::uuid,p_in,p_out,(item->>'adults')::integer,(item->>'children')::integer,nullif(item->>'rate_id','')::uuid,(item->>'unit_id')::uuid,notes,'direct',(item->>'quote')::numeric,coalesce((item->>'contact_permission')::boolean,false),coalesce(item->>'contact_evidence',''));
   else rid:=public.frontdesk_create_existing_guest(p_property,p_currency,child,guest,(item->>'type_id')::uuid,p_in,p_out,(item->>'adults')::integer,(item->>'children')::integer,nullif(item->>'rate_id','')::uuid,(item->>'unit_id')::uuid,notes,'direct',(item->>'quote')::numeric,coalesce((item->>'contact_permission')::boolean,false),coalesce(item->>'contact_evidence',''));end if;
   result:=jsonb_build_object('id',rid,'status','confirmed');
  end if;
  if n=0 then select guest_id into first_guest from public.reservations where id=rid;end if;
  update public.reservations set group_id=group_key where id=rid;
  results:=results||jsonb_build_array(result);n:=n+1;
 end loop;
 update public.reservation_groups set initial_results=results where id=group_key;
 return group_key;
exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'Check the group room and guest details.'using errcode='22023';
end $$;
revoke all on function public.frontdesk_group_create(uuid,text,uuid,text,text,date,date,jsonb,text)from public,anon;
grant execute on function public.frontdesk_group_create(uuid,text,uuid,text,text,date,date,jsonb,text)to authenticated;

create function public.frontdesk_group_detail(p_property uuid,p_group uuid)returns jsonb language plpgsql stable security invoker set search_path=''as $$
declare g public.reservation_groups;
begin
 if not private.has_permission(p_property,'reservations.read')then raise exception 'Reservation access required.'using errcode='42501';end if;
 select *into g from public.reservation_groups where id=p_group and property_id=p_property;
 if not found then raise exception 'Group not found in this hotel.'using errcode='P0002';end if;
 return jsonb_build_object('group',to_jsonb(g)-'request_hash','can_frontdesk',private.has_permission(p_property,'frontdesk.manage'),'can_book',private.has_permission(p_property,'reservations.write'),
 'rows',coalesce((select jsonb_agg(to_jsonb(x)order by x.created_at,x.id)from(
  select r.id,r.version,r.status,r.source,r.check_in,r.check_out,r.adults,r.children,r.total_amount,r.currency,r.created_at,guest.full_name,guest.phone,u.name as room,t.name as type_name
  from public.reservations r join public.guests guest on guest.id=r.guest_id left join public.unit_holds h on h.id=(select id from public.unit_holds where reservation_id=r.id order by active desc,created_at desc limit 1)
  left join public.accommodation_units u on u.id=h.unit_id left join public.accommodation_types t on t.id=u.type_id where r.group_id=p_group and r.property_id=p_property)x),'[]'::jsonb));
end $$;
revoke all on function public.frontdesk_group_detail(uuid,uuid)from public,anon;
grant execute on function public.frontdesk_group_detail(uuid,uuid)to authenticated;
