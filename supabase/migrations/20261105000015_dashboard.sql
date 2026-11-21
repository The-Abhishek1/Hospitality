-- Caller privileges and RLS apply to every dashboard query. No service key.
create function public.dashboard_snapshot(p_property uuid) returns jsonb
language plpgsql stable security invoker set search_path = '' as $$
declare
  p public.properties; d date; start_at timestamptz; end_at timestamptz;
  can_res boolean; can_fin boolean; can_wa boolean; can_channels boolean;
  result jsonb; unit_count int;
begin
  select * into p from public.properties where id = p_property;
  if not found then raise exception 'property not accessible' using errcode = '42501'; end if;
  d := (now() at time zone p.timezone)::date;
  start_at := d::timestamp at time zone p.timezone;
  end_at := (d + 1)::timestamp at time zone p.timezone;
  can_res := private.has_permission(p.id, 'reservations.read');
  can_fin := private.has_permission(p.id, 'finance.read') or private.has_permission(p.id, 'billing.manage');
  can_wa := private.has_permission(p.id, 'whatsapp.use');
  can_channels := private.has_permission(p.id, 'staff.manage');
  select count(*) into unit_count from public.accommodation_units where property_id = p.id and active;
  result := jsonb_build_object(
    'day', d, 'updated_at', now(), 'units', unit_count,
    'permissions', jsonb_build_object('reservations',can_res,'finance',can_fin,'inbox',can_wa,'channels',can_channels,
      'book',private.has_permission(p.id,'reservations.write'), 'inventory',private.has_permission(p.id,'inventory.manage'),
      'tasks',private.has_permission(p.id,'tasks.read'), 'requests',private.has_permission(p.id,'guest_requests.read'),
      'orders',private.has_permission(p.id,'orders.read')),
    'rooms', (select jsonb_build_object('clean',count(*) filter (where housekeeping_status='clean'),
      'dirty',count(*) filter (where housekeeping_status='dirty'),'in_progress',count(*) filter (where housekeeping_status='in_progress'))
      from public.accommodation_units where property_id=p.id and active),
    'forecast', (select jsonb_agg(jsonb_build_object('day',day,'booked',booked,'blocked',blocked) order by day)
      from (select d + n as day,
        (select count(*) from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id
          where h.property_id=p.id and h.active and u.active and h.kind='reservation' and h.during @> (d+n)) as booked,
        (select count(*) from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id
          where h.property_id=p.id and h.active and u.active and h.kind='block' and h.during @> (d+n)) as blocked
        from generate_series(0,6) n) f),
    'tasks', (select jsonb_build_object('open',count(*),'overdue',count(*) filter (where due_at<now()))
      from public.tasks where property_id=p.id and status in ('open','in_progress')),
    'task_list', coalesce((select jsonb_agg(to_jsonb(t)) from (select id,title,kind,priority,due_at,status
      from public.tasks where property_id=p.id and status in ('open','in_progress')
      order by due_at asc nulls last, created_at limit 4) t),'[]'::jsonb)
  );
  if can_res then
    result := result || jsonb_build_object(
      'arrivals', (select count(*) from public.reservations where property_id=p.id and check_in=d and status in ('confirmed','checked_in','checked_out')),
      'arrivals_pending', (select count(*) from public.reservations where property_id=p.id and check_in=d and status='confirmed'),
      'departures', (select count(*) from public.reservations where property_id=p.id and check_out=d and status in ('checked_in','checked_out')),
      'departures_pending', (select count(*) from public.reservations where property_id=p.id and check_out=d and status='checked_in'),
      'in_house', (select count(*) from public.reservations where property_id=p.id and status='checked_in'),
      'late_arrivals', (select count(*) from public.reservations where property_id=p.id and check_in<d and status='confirmed'),
      'stays', coalesce((select jsonb_agg(to_jsonb(t)) from (
        select r.id,g.full_name,r.status,r.check_in,r.check_out,r.source,
          (select u.name from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.reservation_id=r.id and h.active order by u.name limit 1) as room
        from public.reservations r left join public.guests g on g.id=r.guest_id
        where r.property_id=p.id and r.status in ('confirmed','checked_in','checked_out')
          and (r.check_in=d or r.check_out=d or r.status='checked_in')
        order by r.check_in,r.id limit 100) t),'[]'::jsonb));
  end if;
  if can_fin then
    result := result || jsonb_build_object('collections',
      (select coalesce(sum(amount),0) from public.payments where property_id=p.id and created_at>=start_at and created_at<end_at),
      'refunds_today', (select coalesce(sum(amount),0) from public.refunds where property_id=p.id and created_at>=start_at and created_at<end_at),
      'outstanding', (select coalesce(sum(greatest(0,
        coalesce((select sum(amount) from public.folio_items where folio_id=f.id),0)
        -coalesce((select sum(amount) from public.payments where folio_id=f.id),0)
        +coalesce((select sum(r.amount) from public.refunds r join public.payments py on py.id=r.payment_id where py.folio_id=f.id),0)
      )),0) from public.folios f where f.property_id=p.id and f.status='open'));
  end if;
  if can_wa then result := result || jsonb_build_object('conversations',
    (select count(*) from public.conversations where property_id=p.id and status='open')); end if;
  if can_channels then result := result || jsonb_build_object('channel_failures',
    (select count(*) from public.channel_events where property_id=p.id and status in ('failed','dead'))
    +(select count(*) from public.sync_jobs where property_id=p.id and status='dead')); end if;
  return result;
end $$;
revoke all on function public.dashboard_snapshot(uuid) from public, anon;
grant execute on function public.dashboard_snapshot(uuid) to authenticated;
