-- Automatic room-turnaround tasks take a snapshot of current hotel defaults.
create function private.apply_turnaround_defaults()returns trigger language plpgsql security definer set search_path=''as $$
declare s public.property_settings;label text;position integer:=0;
begin
 if new.kind<>'housekeeping'or new.unit_id is null or new.reservation_id is null or new.guest_request_id is not null then return new;end if;
 select * into s from public.property_settings where property_id=new.property_id;if not found then return new;end if;
 for label in select jsonb_array_elements_text(s.cleaning_checklist)loop
 insert into public.task_checklists(tenant_id,property_id,task_id,label,position)values(new.tenant_id,new.property_id,new.id,trim(label),position);position:=position+1;end loop;
 if s.cleaning_target_minutes is not null or s.cleaning_priority<>new.priority or position>0 then
 update public.tasks set due_at=coalesce(new.due_at,case when s.cleaning_target_minutes is not null then now()+make_interval(mins=>s.cleaning_target_minutes)end),priority=case when new.priority='normal'then s.cleaning_priority else new.priority end where id=new.id;
 insert into public.task_events(tenant_id,property_id,task_id,event_type,actor_id,details)values(new.tenant_id,new.property_id,new.id,'defaults_applied',auth.uid(),jsonb_build_object('settings_version',s.version,'checklist_items',position));end if;return new;
end $$;
revoke all on function private.apply_turnaround_defaults()from public,anon,authenticated;
create trigger apply_turnaround_defaults after insert on public.tasks for each row execute function private.apply_turnaround_defaults();

create or replace function public.task_setup(p_property uuid)returns jsonb language plpgsql stable security definer set search_path='' as $$
declare tenant uuid;
begin
 if not private.has_permission(p_property,'tasks.assign')then raise exception 'not permitted'using errcode='42501';end if;
 select tenant_id into tenant from public.properties where id=p_property;
 return jsonb_build_object('cleaning_defaults',(select jsonb_build_object('priority',cleaning_priority,'target_minutes',cleaning_target_minutes,'checklist',cleaning_checklist)from public.property_settings where property_id=p_property),'assignees',coalesce((select jsonb_agg(jsonb_build_object('id',m.user_id,'name',coalesce(pr.full_name,pr.email,'Teammate'))order by pr.full_name)from public.tenant_memberships m join public.profiles pr on pr.id=m.user_id where m.tenant_id=tenant and private.service_task_eligible(p_property,m.user_id)),'[]'::jsonb),
 'departments',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name)order by name)from public.departments where property_id=p_property),'[]'::jsonb),
 'rooms',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'housekeeping_status',housekeeping_status)order by name)from public.accommodation_units where property_id=p_property and active),'[]'::jsonb));
end $$;

create or replace function public.portal_get_stay(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r public.reservations; v jsonb;
begin
  r := private.portal_reservation(p_token);
  select jsonb_build_object(
    'stay', jsonb_build_object('check_in', r.check_in, 'check_out', r.check_out, 'status', r.status, 'adults', r.adults, 'children', r.children),
    'property', private.property_guest_info(r.property_id),
    'guest_name', (select g.full_name from public.guests g where g.id = r.guest_id),
    'unit', (select u.name from public.unit_holds h join public.accommodation_units u on u.id = h.unit_id where h.reservation_id = r.id and h.active limit 1),
    'services', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name) from public.service_catalog s where s.property_id = r.property_id and s.active), '[]'),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'title', q.title, 'status', q.status, 'created_at', q.created_at,
                  'rated', exists (select 1 from public.guest_request_feedback f where f.guest_request_id = q.id)) order by q.created_at desc)
                  from public.guest_requests q where q.reservation_id = r.id), '[]'),
    'menu', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'price', m.price, 'tax_rate_percent', m.tax_rate_percent) order by m.name)
                  from public.menu_items m where m.property_id = r.property_id and m.active), '[]'),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'doc_type', d.doc_type, 'status', d.status) order by d.created_at)
                  from public.guest_documents d where d.reservation_id = r.id), '[]')
  ) into v;
  return v;
end $$;

create or replace function private.create_reservation_core(
  p_property uuid, p_guest uuid, p_type uuid, p_check_in date, p_check_out date, p_adults int, p_children int,
  p_rate_plan uuid, p_source text, p_channel_ref text, p_actor uuid, p_total numeric default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_tenant uuid; v_cur char(3); v_type public.accommodation_types; v_adj numeric := 0; v_id uuid; v_unit uuid; v_total numeric;
begin
  select tenant_id, currency into v_tenant, v_cur from public.properties where id = p_property for share;
  if v_tenant is null then raise exception 'unknown property' using errcode = '22023'; end if;
  if p_check_out <= p_check_in then raise exception 'check_out must be after check_in' using errcode = '22023'; end if;

  select * into v_type from public.accommodation_types where id = p_type and property_id = p_property;
  if not found then raise exception 'unknown accommodation type' using errcode = '22023'; end if;
  if p_adults < 1 or p_adults + p_children > v_type.max_occupancy then raise exception 'occupancy exceeds type capacity' using errcode = '22023'; end if;
  if not exists (select 1 from public.guests where id = p_guest and tenant_id = v_tenant) then raise exception 'guest not found in this tenant' using errcode = '23503'; end if;
  if p_rate_plan is not null then
    select adjustment_percent into v_adj from public.rate_plans where id = p_rate_plan and property_id = p_property;
    if not found then raise exception 'unknown rate plan' using errcode = '22023'; end if;
  end if;

  if p_channel_ref is not null then      -- idempotency for OTA/webhook retries
    select id into v_id from public.reservations where property_id = p_property and source = p_source and channel_ref = p_channel_ref;
    if found then return v_id; end if;
  end if;

  v_total := coalesce(p_total, round(v_type.base_rate * (p_check_out - p_check_in) * (1 + v_adj / 100), 2));
  insert into public.reservations (tenant_id, property_id, guest_id, source, channel_ref, check_in, check_out,
                                   adults, children, rate_plan_id, total_amount, currency, created_by)
  values (v_tenant, p_property, p_guest, p_source, p_channel_ref, p_check_in, p_check_out,
          p_adults, p_children, p_rate_plan, v_total, v_cur, p_actor) returning id into v_id;

  v_unit := private.allocate_unit(p_property, v_tenant, p_type, p_check_in, p_check_out, v_id);
  if v_unit is null then raise exception 'no availability for requested dates' using errcode = 'P0002'; end if;

  insert into public.reservation_events (tenant_id, property_id, reservation_id, event_type, actor_id, details)
  values (v_tenant, p_property, v_id, 'created', p_actor, jsonb_build_object('unit_id', v_unit, 'source', p_source));
  return v_id;
end $$;

create or replace function private.place_order_core(p_property uuid,p_kind text,p_items jsonb,p_reservation uuid,p_table text,p_notes text,p_actor uuid)returns uuid language plpgsql security definer set search_path=''as $$
declare tenant uuid;r public.reservations;unit uuid;created_id uuid;sub numeric:=0;tax_amount numeric:=0;count_items integer:=0;rec record;target integer;
begin
 select tenant_id into tenant from public.properties where id=p_property for share;if tenant is null then raise exception 'unknown property'using errcode='22023';end if;
 if p_kind is null or p_kind not in('restaurant','room_service')then raise exception 'Choose restaurant or room service.'using errcode='22023';end if;
 if p_items is null or jsonb_typeof(p_items)<>'array'or jsonb_array_length(p_items)not between 1 and 30 then raise exception 'Choose 1–30 different menu items.'using errcode='22023';end if;
 if length(coalesce(p_table,''))>40 or length(coalesce(p_notes,''))>2000 then raise exception 'Keep table labels under 40 characters and instructions under 2000.'using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements(p_items)x where case when coalesce(x->>'quantity','')~'^[1-9][0-9]?$'then(x->>'quantity')::integer not between 1 and 50 else true end)then raise exception 'Use quantities of 1–50.'using errcode='22023';end if;
 if(select count(distinct x->>'menu_item_id')from jsonb_array_elements(p_items)x)<>jsonb_array_length(p_items)then raise exception 'Each menu item may appear once in the cart.'using errcode='22023';end if;
 if p_reservation is not null then
 select * into r from public.reservations where id=p_reservation and property_id=p_property for update;if not found or r.status<>'checked_in'then raise exception 'Choose an in-house guest for room charges.'using errcode='22023';end if;
 select unit_id into unit from public.unit_holds where reservation_id=r.id and active order by created_at desc limit 1;
 elsif p_kind='room_service'then raise exception 'Room service requires an in-house stay.'using errcode='22023';end if;
 -- Stable snapshots: menu edits wait until the order has copied its prices and taxes.
 perform mi.id from public.menu_items mi join jsonb_to_recordset(p_items)as x(menu_item_id uuid,quantity integer)on mi.id=x.menu_item_id where mi.property_id=p_property and mi.active order by mi.id for share of mi;
 insert into public.orders(tenant_id,property_id,kind,reservation_id,unit_id,table_label,notes,placed_by,source)values(tenant,p_property,p_kind,p_reservation,unit,nullif(trim(p_table),''),nullif(trim(p_notes),''),p_actor,case when p_actor is null then 'guest_portal'else 'staff'end)returning id into created_id;
 for rec in select mi.*,x.quantity from public.menu_items mi join jsonb_to_recordset(p_items)as x(menu_item_id uuid,quantity integer)on mi.id=x.menu_item_id where mi.property_id=p_property and mi.active order by mi.id loop
 insert into public.order_items(tenant_id,property_id,order_id,menu_item_id,name_snapshot,unit_price,tax_rate_percent,quantity)values(tenant,p_property,created_id,rec.id,rec.name,rec.price,rec.tax_rate_percent,rec.quantity);
 sub:=sub+rec.price*rec.quantity;tax_amount:=tax_amount+round(rec.price*rec.quantity*rec.tax_rate_percent/100,2);count_items:=count_items+1;target:=greatest(target,rec.prep_minutes);end loop;
 if sub+tax_amount>9999999999.99 then raise exception 'Order total exceeds the supported amount. Split it into smaller orders.'using errcode='22023';end if;
 if count_items<>jsonb_array_length(p_items)then raise exception 'A menu item is unavailable. Review the menu and try again.'using errcode='22023';end if;
 update public.orders set subtotal=sub,tax=tax_amount,total=sub+tax_amount,due_at=case when target is not null then now()+make_interval(mins=>target)end where id=created_id;
 insert into public.kitchen_events(tenant_id,property_id,order_id,event_type,actor_id)values(tenant,p_property,created_id,'placed',p_actor);return created_id;
end $$;
