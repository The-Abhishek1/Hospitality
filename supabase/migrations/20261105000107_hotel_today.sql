-- Daily work uses live, property-scoped records and the caller's RLS policies.
-- Completed stays are daily activity, not outstanding check-in/checkout work.
create function public.hotel_today(p_property uuid,p_filters jsonb default '{}') returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare
 result jsonb; work jsonb; d date; q text:=coalesce(p_filters->>'queue',''); pg integer:=1;
 can_res boolean; can_docs boolean; can_inbox boolean; can_tasks boolean;
 rows jsonb; counts jsonb; total integer;
begin
 result:=public.dashboard_snapshot(p_property); d:=(result->>'day')::date;
 can_res:=private.has_permission(p_property,'reservations.read');
 can_docs:=can_res and private.has_permission(p_property,'documents.review');
 can_inbox:=private.has_permission(p_property,'whatsapp.use');
 can_tasks:=private.has_permission(p_property,'tasks.read');
 if coalesce(p_filters->>'page','')~'^[0-9]{1,6}$'then pg:=greatest(1,least(100000,(p_filters->>'page')::integer));end if;
 with stays as materialized(select *from public.reservations where property_id=p_property),
 unanswered as materialized(
  select c.id from public.conversations c
  join lateral(select m.created_at,m.id from public.messages m where m.conversation_id=c.id and m.direction='in'order by m.created_at desc,m.id desc limit 1)i on true
  left join lateral(select m.created_at,m.id from public.messages m where m.conversation_id=c.id and m.direction='out'and m.status in('sent','delivered','read')order by m.created_at desc,m.id desc limit 1)o on true
  where c.property_id=p_property and c.status='open'and(o.id is null or(i.created_at,i.id)>(o.created_at,o.id))
 )select jsonb_build_object(
  'arrivals',case when can_res then(select count(*)from stays where status='confirmed'and check_in<=d and check_out>d)end,
  'departures',case when can_res then(select count(*)from stays where status='checked_in'and check_out<=d)end,
  'documents',case when can_docs then(select count(distinct r.id)from stays r join public.guest_documents doc on doc.reservation_id=r.id where r.status in('confirmed','checked_in')and doc.status in('uploaded','clean','image_ready'))end,
  'inbox',case when can_inbox then(select count(*)from unanswered)end
 )into counts;
 if q not in('arrivals','departures','documents','inbox')or counts->>q is null then
  q:=case when coalesce((counts->>'arrivals')::int,0)>0 then'arrivals'when coalesce((counts->>'documents')::int,0)>0 then'documents'when coalesce((counts->>'departures')::int,0)>0 then'departures'when coalesce((counts->>'inbox')::int,0)>0 then'inbox'when can_res then'arrivals'when can_inbox then'inbox'else''end;
 end if;
 total:=coalesce((counts->>q)::integer,0);pg:=least(pg,greatest(1,(total+5)/6));
 if q in('arrivals','departures','documents')then
  with candidates as materialized(
   select r.*,g.full_name,
    (select count(*)from public.guest_documents doc where doc.reservation_id=r.id and doc.status in('uploaded','clean','image_ready'))as pending_documents
   from public.reservations r left join public.guests g on g.id=r.guest_id
   where r.property_id=p_property and(
    q='arrivals'and r.status='confirmed'and r.check_in<=d and r.check_out>d
    or q='departures'and r.status='checked_in'and r.check_out<=d
    or q='documents'and r.status in('confirmed','checked_in')and exists(select 1 from public.guest_documents doc where doc.reservation_id=r.id and doc.status in('uploaded','clean','image_ready')))
   order by case when q='departures'then r.check_out else r.check_in end,r.id limit 6 offset(pg-1)*6
  )select coalesce(jsonb_agg(jsonb_build_object(
   'id',r.id,'version',r.version,'full_name',r.full_name,'check_in',r.check_in,'check_out',r.check_out,'status',r.status,'source',r.source,
   'room',(select u.name from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.reservation_id=r.id and h.active and h.kind='reservation'order by u.name limit 1),
   'room_state',(select u.housekeeping_status from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.reservation_id=r.id and h.active and h.kind='reservation'order by u.name limit 1),
   'room_active',(select u.active from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.reservation_id=r.id and h.active and h.kind='reservation'order by u.name limit 1),
   'room_occupied',exists(select 1 from public.unit_holds own join public.unit_holds h on h.unit_id=own.unit_id join public.reservations other on other.id=h.reservation_id where own.reservation_id=r.id and own.active and h.active and other.id<>r.id and other.status='checked_in'),
   'document_error',case when q='arrivals'then public.whatsapp_journey_workspace(p_property,r.id)->>'document_error'end,
   'pending_documents',case when can_docs then r.pending_documents end,
   'finance',case when q='departures'then public.reservation_detail(p_property,r.id)->'finance'end
  )order by case when q='departures'then r.check_out else r.check_in end,r.id),'[]'::jsonb)into rows from candidates r;
 elsif q='inbox'then
  select coalesce(jsonb_agg(to_jsonb(x)order by x.human_handoff desc,x.received_at,x.id),'[]'::jsonb)into rows from(
   select c.id,coalesce(c.contact_name,'Guest')as full_name,c.human_handoff,i.created_at as received_at,left(i.body,160)as preview
   from public.conversations c
   join lateral(select m.id,m.created_at,m.body from public.messages m where m.conversation_id=c.id and m.direction='in'order by m.created_at desc,m.id desc limit 1)i on true
   left join lateral(select m.id,m.created_at from public.messages m where m.conversation_id=c.id and m.direction='out'and m.status in('sent','delivered','read')order by m.created_at desc,m.id desc limit 1)o on true
   where c.property_id=p_property and c.status='open'and(o.id is null or(i.created_at,i.id)>(o.created_at,o.id))
   order by c.human_handoff desc,i.created_at,c.id limit 6 offset(pg-1)*6
  )x;
 end if;
 work:=jsonb_build_object('counts',counts,'queue',q,'page',pg,'total',total,'rows',coalesce(rows,'[]'::jsonb),
  'can_frontdesk',private.has_permission(p_property,'frontdesk.manage'),'can_review',can_docs);
 return(result-'stays'-'forecast'-'outstanding')||jsonb_build_object('work',work,
  'tonight',result#>'{forecast,0}',
  'rooms_to_clean',case when can_tasks or private.has_permission(p_property,'inventory.manage')then coalesce((select jsonb_agg(to_jsonb(x)order by x.name,x.id)from(
   select u.id,u.name,u.housekeeping_status from public.accommodation_units u where u.property_id=p_property and u.active and u.housekeeping_status in('dirty','in_progress')order by u.name,u.id limit 5)x),'[]'::jsonb)else'[]'::jsonb end);
end $$;
revoke all on function public.hotel_today(uuid,jsonb)from public,anon;
grant execute on function public.hotel_today(uuid,jsonb)to authenticated;
