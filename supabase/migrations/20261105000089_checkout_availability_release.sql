-- Early checkout must free future availability while retaining past-night inventory history.
create or replace function public.check_out_reservation(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.reservations; v record; v_task uuid; v_bal numeric; v_day date;
begin
  r := private.lock_reservation(p_id, 'frontdesk.manage');
  if r.status <> 'checked_in' then raise exception 'cannot check out from status %', r.status using errcode = '22023'; end if;

  perform private.post_room_nights(p_id, r.check_out - 1);   -- the booked stay is always fully charged
  v_bal := private.reservation_balance(p_id);
  if v_bal <> 0 then raise exception 'settle the folio before checkout (balance %)', v_bal using errcode = '22023'; end if;

  update public.reservations set status = 'checked_out', checked_out_at = now() where id = p_id;
  for v in select h.unit_id, u.name from public.unit_holds h
           join public.accommodation_units u on u.id = h.unit_id
           where h.reservation_id = p_id and h.active
  loop
    update public.accommodation_units set housekeeping_status = 'dirty' where id = v.unit_id;
    v_task := null;
    insert into public.tasks (tenant_id, property_id, title, kind, unit_id, reservation_id, created_by)
    values (r.tenant_id, r.property_id, 'Clean unit ' || v.name, 'housekeeping', v.unit_id, p_id, auth.uid())
    on conflict (unit_id) where kind = 'housekeeping' and status in ('open', 'in_progress') do nothing
    returning id into v_task;
    if v_task is not null then
      insert into public.task_events (tenant_id, property_id, task_id, event_type, actor_id, details)
      values (r.tenant_id, r.property_id, v_task, 'created', auth.uid(), jsonb_build_object('source', 'checkout'));
    end if;
  end loop;
  -- Keep past occupied nights for reports; release the remaining booked nights after early departure.
  select (now() at time zone p.timezone)::date into v_day from public.properties p where p.id=r.property_id;
  update public.unit_holds set active=false
    where reservation_id=p_id and active and lower(during)>=v_day;
  update public.unit_holds set during=daterange(lower(during),v_day,'[)')
    where reservation_id=p_id and active and lower(during)<v_day and upper(during)>v_day;
  insert into public.reservation_events (tenant_id, property_id, reservation_id, event_type, actor_id)
  values (r.tenant_id, r.property_id, p_id, 'checked_out', auth.uid());
end $$;

-- Repair only the unused portion of holds belonging to completed departures.
-- Amounts, stay dates, invoices and prior occupied nights remain as recorded.
update public.unit_holds h set active=false
from public.reservations r,public.properties p
where h.reservation_id=r.id and p.id=r.property_id and p.archived_at is null and r.status='checked_out'
and r.checked_out_at is not null and h.active
and lower(h.during)>=(r.checked_out_at at time zone p.timezone)::date;
update public.unit_holds h set during=daterange(lower(h.during),(r.checked_out_at at time zone p.timezone)::date,'[)')
from public.reservations r,public.properties p
where h.reservation_id=r.id and p.id=r.property_id and p.archived_at is null and r.status='checked_out'
and r.checked_out_at is not null and h.active
and lower(h.during)<(r.checked_out_at at time zone p.timezone)::date
and upper(h.during)>(r.checked_out_at at time zone p.timezone)::date;
