-- Room operations reuse the task workflow and its checklist, audit and assignment rules.
create function private.inventory_room_operations(p_property uuid,p_unit uuid)returns jsonb
language sql stable security definer set search_path=''as $$
 select jsonb_build_object(
 'type_name',ty.name,'max_occupancy',ty.max_occupancy,'base_rate',ty.base_rate,
 'occupied',exists(select 1 from public.unit_holds h join public.reservations r on r.id=h.reservation_id where h.unit_id=u.id and h.active and r.status='checked_in'),
 'blocked_today',exists(select 1 from public.unit_holds h where h.unit_id=u.id and h.active and h.kind='block'and h.during@>(now()at time zone p.timezone)::date),
 'reserved_today',exists(select 1 from public.unit_holds h join public.reservations r on r.id=h.reservation_id where h.unit_id=u.id and h.active and h.during@>(now()at time zone p.timezone)::date and r.status in('confirmed','checked_in')),
 'current_stay',case when private.has_permission(p.id,'reservations.read')then(select r.id from public.unit_holds h join public.reservations r on r.id=h.reservation_id where h.unit_id=u.id and h.active and r.status='checked_in'order by r.check_in,r.id limit 1)end,
 'cleaning_task',case when private.has_permission(p.id,'tasks.read')or private.has_permission(p.id,'tasks.assign')then(select jsonb_build_object('id',t.id,'status',t.status,'linked_request',t.guest_request_id is not null,'remaining',(select count(*)from public.task_checklists c where c.task_id=t.id and not c.done))from public.tasks t where t.unit_id=u.id and t.kind='housekeeping'and t.status in('open','in_progress')and private.task_visible(t.id)order by t.created_at,t.id limit 1)end)
 from public.accommodation_units u join public.properties p on p.id=u.property_id join public.accommodation_types ty on ty.id=u.type_id where u.id=p_unit and u.property_id=p_property
$$;
revoke all on function private.inventory_room_operations(uuid,uuid)from public,anon,authenticated,service_role;
alter function public.inventory_workspace(uuid,jsonb)rename to inventory_workspace_before_room_operations;
revoke all on function public.inventory_workspace_before_room_operations(uuid,jsonb)from public,anon,authenticated,service_role;
create function public.inventory_workspace(p_property uuid,p_filters jsonb default '{}')returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare result jsonb;d date;
begin
 result:=public.inventory_workspace_before_room_operations(p_property,p_filters);d:=(result->>'day')::date;
 if coalesce(p_filters->>'mode','rooms')='rooms'then result:=jsonb_set(result,'{rows}',coalesce((select jsonb_agg(x||private.inventory_room_operations(p_property,(x->>'id')::uuid)order by n)from jsonb_array_elements(result->'rows')with ordinality a(x,n)),'[]'::jsonb));end if;
 return result||jsonb_build_object('can_manage_tasks',private.has_permission(p_property,'tasks.assign'),'can_tasks',private.has_permission(p_property,'tasks.read')or private.has_permission(p_property,'tasks.assign'),'can_reservations',private.has_permission(p_property,'reservations.read'),
 'stats',(result->'stats')||jsonb_build_object('dirty',(select count(*)from public.accommodation_units where property_id=p_property and active and housekeeping_status<>'clean'),
 'occupied',(select count(*)from public.accommodation_units u where u.property_id=p_property and u.active and exists(select 1 from public.unit_holds h join public.reservations r on r.id=h.reservation_id where h.unit_id=u.id and h.active and r.status='checked_in')),
 'blocked_today',(select count(*)from public.accommodation_units u where u.property_id=p_property and u.active and exists(select 1 from public.unit_holds h where h.unit_id=u.id and h.active and h.kind='block'and h.during@>d))));
end $$;
alter function public.inventory_detail(uuid,text,uuid)rename to inventory_detail_before_room_operations;
revoke all on function public.inventory_detail_before_room_operations(uuid,text,uuid)from public,anon,authenticated,service_role;
create function public.inventory_detail(p_property uuid,p_section text,p_id uuid default null)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare result jsonb;
begin
 result:=public.inventory_detail_before_room_operations(p_property,p_section,p_id);
 if p_section='rooms'and p_id is not null then result:=jsonb_set(result,'{item}',(result->'item')||private.inventory_room_operations(p_property,p_id));end if;
 return result||jsonb_build_object('can_manage_tasks',private.has_permission(p_property,'tasks.assign'),'can_tasks',private.has_permission(p_property,'tasks.read')or private.has_permission(p_property,'tasks.assign'),'can_reservations',private.has_permission(p_property,'reservations.read'));
end $$;
create function public.inventory_cleaning_action(p_property uuid,p_unit uuid,p_version integer,p_request uuid,p_action text)returns uuid
language plpgsql security definer set search_path=''as $$
declare u public.accommodation_units;t public.tasks;cmd public.inventory_commands;payload jsonb;details jsonb;defaults jsonb;result uuid;
begin
 perform private.staff_share(p_property);
 if not private.has_permission(p_property,'inventory.manage')or not private.has_permission(p_property,'tasks.assign')then raise exception 'Inventory and task-management access required.'using errcode='42501';end if;
 if p_request is null or p_action is null or p_action not in('start','complete')then raise exception 'Choose a cleaning action.'using errcode='22023';end if;
 payload:=jsonb_build_object('version',p_version,'action',p_action);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('inventory-command:'||p_property::text||p_request::text,0));
 select *into cmd from public.inventory_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.action<>'cleaning'or cmd.entity_id is distinct from p_unit or cmd.payload is distinct from payload then raise exception 'Request ID already used for different details.'using errcode='22023';end if;return cmd.result_id;end if;
 select *into u from public.accommodation_units where id=p_unit and property_id=p_property for update;
 if not found or not u.active then raise exception 'Choose an active room in this hotel.'using errcode='22023';end if;
 if u.version is distinct from p_version then raise exception 'Room changed. Refresh before continuing.'using errcode='40001';end if;
 select *into t from public.tasks where unit_id=u.id and kind='housekeeping'and status in('open','in_progress')order by created_at,id limit 1;
 -- Linked guest requests retain their own request-before-room lock order and workflow.
 if t.guest_request_id is not null then raise exception 'Open the linked cleaning task to update this guest request.'using errcode='22023';end if;
 if t.id is null then
  if p_action='complete'then raise exception 'Start or assign cleaning first, then complete its checklist.'using errcode='22023';end if;
  defaults:=public.task_setup(p_property)->'cleaning_defaults';
  details:=jsonb_build_object('title','Clean room '||u.name,'kind','housekeeping','priority',coalesce(defaults->>'priority','normal'),'unit',u.id,'target_minutes',defaults->>'target_minutes','checklist',coalesce(defaults->'checklist','["Inspect room cleanliness"]'::jsonb));
  result:=public.task_create_advanced(p_property,pg_catalog.gen_random_uuid(),details);select *into t from public.tasks where id=result;
 end if;
 perform public.task_action(p_property,t.id,t.version,p_request,'status',jsonb_build_object('status',case p_action when'start'then'in_progress'else'done'end,'reason','Updated from room inventory'));
 insert into public.inventory_commands(tenant_id,property_id,request_id,action,entity_id,payload,result_id)values(u.tenant_id,p_property,p_request,'cleaning',u.id,payload,t.id);return t.id;
end $$;
revoke all on function public.inventory_workspace(uuid,jsonb),public.inventory_detail(uuid,text,uuid),public.inventory_cleaning_action(uuid,uuid,integer,uuid,text)from public,anon;
grant execute on function public.inventory_workspace(uuid,jsonb),public.inventory_detail(uuid,text,uuid),public.inventory_cleaning_action(uuid,uuid,integer,uuid,text)to authenticated;
