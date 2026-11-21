create function public.inventory_workspace(p_property uuid,p_filters jsonb default '{}')returns jsonb language plpgsql stable security definer set search_path='' as $$
declare prop public.properties;day date;result jsonb;mode text:=coalesce(p_filters->>'mode','rooms');query text:=left(trim(coalesce(p_filters->>'q','')),100);state_filter text:=coalesce(p_filters->>'state','all');pg integer:=greatest(1,least(100000,coalesce((p_filters->>'page')::integer,1)));
begin
 if not private.has_permission(p_property,'inventory.manage')then raise exception 'not permitted'using errcode='42501';end if;
 select * into prop from public.properties where id=p_property;day:=(now()at time zone prop.timezone)::date;
 if mode='types'then
 with rows as materialized(select t.*, (select count(*)from public.accommodation_units u where u.type_id=t.id and u.active)as active_rooms,(select count(*)from public.accommodation_units u where u.type_id=t.id)as total_rooms from public.accommodation_types t where t.property_id=p_property and(query=''or strpos(lower(t.name||' '||t.kind),lower(query))>0))select jsonb_build_object('total',(select count(*)from rows),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select * from rows order by name,id limit 20 offset(pg-1)*20)x),'[]'::jsonb))into result;
 elsif mode='rates'then
 with rows as materialized(select * from public.rate_plans r where property_id=p_property and(query=''or strpos(lower(r.name||' '||r.code),lower(query))>0))select jsonb_build_object('total',(select count(*)from rows),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select * from rows order by name,id limit 20 offset(pg-1)*20)x),'[]'::jsonb))into result;
 elsif mode='blocks'then
 with rows as materialized(select h.id,h.version,h.unit_id,u.name as room,lower(h.during)as "from",upper(h.during)as "to",h.reason,h.active,h.created_at,case when not h.active then 'released'when upper(h.during)<=day then 'expired'when lower(h.during)>day then 'upcoming'else 'current'end as status from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.property_id=p_property and h.kind='block'and(query=''or strpos(lower(u.name||' '||coalesce(h.reason,'')),lower(query))>0)),filtered as materialized(select * from rows where state_filter='all'or(state_filter='active'and status in('current','upcoming'))or status=state_filter)select jsonb_build_object('total',(select count(*)from filtered),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select * from filtered order by active desc,"from"desc,id desc limit 20 offset(pg-1)*20)x),'[]'::jsonb))into result;
 else
 with rows as materialized(select u.*,t.name as type_name,t.kind,t.max_occupancy,t.base_rate,
 exists(select 1 from public.unit_holds h join public.reservations r on r.id=h.reservation_id where h.unit_id=u.id and h.active and r.status='checked_in')as occupied,
 exists(select 1 from public.unit_holds h where h.unit_id=u.id and h.active and h.kind='block'and h.during@>day)as blocked_today,
 (select count(*)from public.unit_holds h where h.unit_id=u.id and h.active and(upper_inf(h.during)or upper(h.during)>day))as upcoming_holds,
 (select count(*)from public.tasks where unit_id=u.id and status in('open','in_progress'))as open_tasks
 from public.accommodation_units u join public.accommodation_types t on t.id=u.type_id where u.property_id=p_property and(query=''or strpos(lower(concat_ws(' ',u.name,t.name,u.floor)),lower(query))>0)and(coalesce(p_filters->>'type','')=''or u.type_id::text=p_filters->>'type')),
 filtered as materialized(select * from rows where case state_filter when 'active'then active when 'inactive'then not active when 'dirty'then active and housekeeping_status<>'clean'when 'occupied'then occupied when 'blocked'then blocked_today else true end)
 select jsonb_build_object('total',(select count(*)from filtered),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select * from filtered order by active desc,name,id limit 20 offset(pg-1)*20)x),'[]'::jsonb))into result;
 end if;
 return result||jsonb_build_object('page',pg,'day',day,'currency',prop.currency,'timezone',prop.timezone,'stats',jsonb_build_object('rooms',(select count(*)from public.accommodation_units where property_id=p_property),'active',(select count(*)from public.accommodation_units where property_id=p_property and active),'types',(select count(*)from public.accommodation_types where property_id=p_property),'blocks',(select count(*)from public.unit_holds where property_id=p_property and kind='block'and active and(upper_inf(during)or upper(during)>day))),
 'types',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name)order by name)from public.accommodation_types where property_id=p_property),'[]'::jsonb));
end $$;

create function public.inventory_detail(p_property uuid,p_section text,p_id uuid default null)returns jsonb language plpgsql stable security definer set search_path='' as $$
declare prop public.properties;item jsonb;result jsonb;day date;
begin
 if not private.has_permission(p_property,'inventory.manage')then raise exception 'not permitted'using errcode='42501';end if;
 if p_section not in('rooms','types','rates','blocks')then raise exception 'Unknown inventory section.'using errcode='22023';end if;
 select * into prop from public.properties where id=p_property;day:=(now()at time zone prop.timezone)::date;
 if p_id is not null then
 if p_section='rooms'then select to_jsonb(u)into item from public.accommodation_units u where id=p_id and property_id=p_property;
 elsif p_section='types'then select to_jsonb(t)into item from public.accommodation_types t where id=p_id and property_id=p_property;
 elsif p_section='rates'then select to_jsonb(r)into item from public.rate_plans r where id=p_id and property_id=p_property;
 else select jsonb_build_object('id',h.id,'version',h.version,'unit_id',h.unit_id,'room',u.name,'from',lower(h.during),'to',upper(h.during),'reason',h.reason,'active',h.active)into item from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.id=p_id and h.property_id=p_property and h.kind='block';end if;
 if item is null then raise exception 'Inventory item not found in this hotel.'using errcode='P0002';end if;end if;
 result:=jsonb_build_object('item',item,'day',day,'currency',prop.currency,'timezone',prop.timezone,
 'types',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name)order by name)from public.accommodation_types where property_id=p_property),'[]'::jsonb),
 'rooms',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name)order by name)from public.accommodation_units where property_id=p_property and active),'[]'::jsonb),
 'events',coalesce((select jsonb_agg(to_jsonb(x))from(select e.id,e.action,e.details,e.created_at,coalesce(pr.full_name,pr.email,'Staff / system')as actor_name from public.inventory_events e left join public.profiles pr on pr.id=e.actor_id where e.property_id=p_property and e.entity=p_section and e.entity_id=p_id order by e.created_at desc,e.id desc limit 20)x),'[]'::jsonb));
 if p_section='rooms'and p_id is not null then
 result:=result||jsonb_build_object('holds',coalesce((select jsonb_agg(to_jsonb(x))from(select h.id,h.kind,lower(h.during)as "from",upper(h.during)as "to",h.reason,h.reservation_id,h.version from public.unit_holds h left join public.reservations r on r.id=h.reservation_id where h.unit_id=p_id and h.active and(upper_inf(h.during)or upper(h.during)>day or r.status='checked_in')order by lower(h.during),h.id limit 20)x),'[]'::jsonb),
 'hold_total',(select count(*)from public.unit_holds h left join public.reservations r on r.id=h.reservation_id where h.unit_id=p_id and h.active and(upper_inf(h.during)or upper(h.during)>day or r.status='checked_in')),
 'can_reservations',private.has_permission(p_property,'reservations.read'),'can_tasks',private.has_permission(p_property,'tasks.read'));
 end if;return result;
end $$;
revoke all on function public.inventory_workspace(uuid,jsonb),public.inventory_detail(uuid,text,uuid)from public,anon;
grant execute on function public.inventory_workspace(uuid,jsonb),public.inventory_detail(uuid,text,uuid)to authenticated;
