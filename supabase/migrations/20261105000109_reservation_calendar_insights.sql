-- Property-wide current room insights; existing calendar/list permissions and pagination remain unchanged.
create or replace function public.reservation_workspace(p_property uuid,p_filters jsonb default '{}') returns jsonb
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
   select u.id,u.name,u.type_id,t.name as type_name,u.housekeeping_status,(select r.id from public.unit_holds h join public.reservations r on r.id=h.reservation_id where h.unit_id=u.id and h.active and r.status='checked_in'order by r.check_in,r.id limit 1)as current_stay,coalesce((select jsonb_agg(jsonb_build_object('id',h.id,'during',h.during::text,'kind',h.kind,'reservation_id',h.reservation_id,'guest',g.full_name,'status',r.status,'reason',h.reason)) from public.unit_holds h left join public.reservations r on r.id=h.reservation_id left join public.guests g on g.id=r.guest_id where h.unit_id=u.id and h.active and h.during&&daterange(start_day,start_day+14,'[)')),'[]'::jsonb) as holds
   from public.accommodation_units u join public.accommodation_types t on t.id=u.type_id where u.property_id=p_property and u.active order by u.name,u.id limit 12 offset(room_page-1)*12)x),'[]'::jsonb));

 with rooms as materialized(
  select u.housekeeping_status,
   exists(select 1 from public.unit_holds h join public.reservations r on r.id=h.reservation_id where h.unit_id=u.id and h.active and r.status='checked_in')as occupied,
   exists(select 1 from public.unit_holds h join public.reservations r on r.id=h.reservation_id where h.unit_id=u.id and h.active and h.during@>d and r.status='confirmed')as booked,
   exists(select 1 from public.unit_holds h where h.unit_id=u.id and h.active and h.kind='block'and h.during@>d)as blocked
  from public.accommodation_units u where u.property_id=p_property and u.active
 )select result||jsonb_build_object('room_insights',jsonb_build_object(
  'day',d,'total',count(*),'booked',count(*)filter(where booked),
  'in_house',count(*)filter(where occupied),'blocked',count(*)filter(where blocked),
  'empty',count(*)filter(where not occupied and not booked and not blocked),
  'ready',count(*)filter(where not occupied and not booked and not blocked and housekeeping_status='clean'),
  'dirty',count(*)filter(where housekeeping_status='dirty'),'cleaning',count(*)filter(where housekeeping_status='in_progress'),
  'clean',count(*)filter(where housekeeping_status='clean')
 ))into result from rooms;
 return result;
end $$;

revoke all on function public.reservation_workspace(uuid,jsonb)from public,anon;
grant execute on function public.reservation_workspace(uuid,jsonb)to authenticated;
