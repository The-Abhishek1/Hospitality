-- Serialize room configuration with automatic and explicit room allocation.
create or replace function private.allocate_unit(p_property uuid, p_tenant uuid, p_type uuid, p_in date, p_out date, p_reservation uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_unit uuid;
begin
  for v_unit in
    select u.id from public.accommodation_units u
    where u.property_id = p_property and u.type_id = p_type and u.active
      and not exists (select 1 from public.unit_holds h where h.unit_id = u.id and h.active and h.during && daterange(p_in, p_out, '[)'))
    order by u.name for update of u
  loop
    begin
      insert into public.unit_holds (tenant_id, property_id, unit_id, during, kind, reservation_id)
      values (p_tenant, p_property, v_unit, daterange(p_in, p_out, '[)'), 'reservation', p_reservation);
      return v_unit;
    exception when exclusion_violation then null;     -- lost the race for this unit; try the next
    end;
  end loop;
  return null;
end $$;

create or replace function private.frontdesk_allocate(p_property uuid,p_tenant uuid,p_type uuid,p_in date,p_out date,p_res uuid,p_unit uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare u uuid;
begin
 if p_unit is null then
  u:=private.allocate_unit(p_property,p_tenant,p_type,p_in,p_out,p_res);
  if u is null then raise exception 'No availability for those dates. Choose another room type or date range.' using errcode='P0002';end if;
  return u;
 end if;
 perform 1 from public.accommodation_units where id=p_unit and property_id=p_property and type_id=p_type and active for update;
 if not found then
  raise exception 'Selected room is not active or does not match the room type.' using errcode='22023';end if;
 insert into public.unit_holds(tenant_id,property_id,unit_id,during,kind,reservation_id)
 values(p_tenant,p_property,p_unit,daterange(p_in,p_out,'[)'),'reservation',p_res);
 return p_unit;
end $$;
