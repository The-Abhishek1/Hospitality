-- Bulk housekeeping retains room versions, task checklists and per-room results.
create table private.inventory_bulk_commands(property_id uuid not null references public.properties(id)on delete cascade,request_id uuid not null,payload jsonb not null,result jsonb not null,primary key(property_id,request_id));
revoke all on private.inventory_bulk_commands from public,anon,authenticated,service_role;
create function public.inventory_room_selection(p_property uuid,p_filters jsonb default '{}')returns jsonb language plpgsql stable security definer set search_path=''as $$
declare workspace jsonb;rows jsonb:='[]';pg integer:=1;
begin
 loop
  workspace:=public.inventory_workspace(p_property,coalesce(p_filters,'{}')||jsonb_build_object('mode','rooms','page',pg));
  if(workspace->>'total')::integer>200 then raise exception 'Select up to 200 matching rooms at once. Narrow your filters first.'using errcode='22023';end if;
  rows:=rows||coalesce((select jsonb_agg(jsonb_build_object('id',x->>'id','version',(x->>'version')::integer,'name',x->>'name'))from jsonb_array_elements(workspace->'rows')x where(x->>'active')::boolean),'[]'::jsonb);
  exit when pg*20>=(workspace->>'total')::integer;pg:=pg+1;
 end loop;return rows;
end $$;
create function public.inventory_bulk_rooms(p_property uuid,p_request uuid,p_items jsonb,p_action text,p_assignee uuid default null)returns jsonb
language plpgsql security definer set search_path=''as $$
declare item jsonb;u public.accommodation_units;t public.tasks;previous private.inventory_bulk_commands;payload jsonb;results jsonb:='[]';result jsonb;defaults jsonb;tenant uuid;
begin
 perform private.staff_share(p_property);
 if not private.has_permission(p_property,'inventory.manage')or not private.has_permission(p_property,'tasks.assign')then raise exception 'Inventory and task-management access required.'using errcode='42501';end if;
 if p_request is null or p_action is null or p_action not in('clean','start','assign')or jsonb_typeof(p_items)is distinct from'array'or (jsonb_array_length(p_items)not between 1 and 200 or length(p_items::text)>50000)then raise exception 'Select 1–200 rooms and a bulk action.'using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements(p_items)x where jsonb_typeof(x)<>'object'or coalesce(x->>'id','')!~*'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'or coalesce(x->>'version','')!~'^[0-9]{1,9}$')or(select count(distinct x->>'id')from jsonb_array_elements(p_items)x)<>jsonb_array_length(p_items)then raise exception 'Refresh the room selection.'using errcode='22023';end if;
 if p_action='assign'and(p_assignee is null or not private.service_task_eligible(p_property,p_assignee))then raise exception 'Choose a teammate with task-write access to this hotel.'using errcode='22023';end if;
 payload:=jsonb_build_object('items',p_items,'action',p_action,'assignee',p_assignee);
 perform pg_advisory_xact_lock(hashtextextended('inventory-bulk:'||p_property::text||p_request::text,0));
 select *into previous from private.inventory_bulk_commands where property_id=p_property and request_id=p_request;
 if found then if previous.payload is distinct from payload then raise exception 'This request was used with another selection. Refresh.'using errcode='22023';end if;return previous.result;end if;
 select tenant_id into tenant from public.properties where id=p_property;
 -- A consistent room lock order also serializes overlapping batches.
 for item in select x from jsonb_array_elements(p_items)x order by x->>'id'loop
  begin
   select *into u from public.accommodation_units where id=(item->>'id')::uuid and property_id=p_property for update;
   if not found or not u.active then raise exception 'Room unavailable or inactive.'using errcode='22023';end if;
   if u.version<>(item->>'version')::integer then raise exception 'Room changed. Select it again after refreshing.'using errcode='40001';end if;
   select *into t from public.tasks where unit_id=u.id and kind='housekeeping'and status in('open','in_progress')order by created_at,id limit 1;
   if(select count(*)from public.tasks where unit_id=u.id and kind='housekeeping'and status in('open','in_progress'))>1 then raise exception 'Review this room’s multiple open cleaning tasks first.'using errcode='22023';end if;
   if t.guest_request_id is not null then raise exception 'Open the linked guest-request task to update this room.'using errcode='22023';end if;
   if p_action='clean'then
    if t.id is not null then
     if exists(select 1 from public.task_checklists where task_id=t.id and not done)then raise exception 'Finish the cleaning checklist before marking this room clean.'using errcode='22023';end if;
     perform public.task_action(p_property,t.id,t.version,gen_random_uuid(),'status','{"status":"done","reason":"Room inspected in bulk room management"}'::jsonb);
    else update public.accommodation_units set housekeeping_status='clean'where id=u.id and housekeeping_status<>'clean';end if;
   elsif p_action='start'then
    if t.status is distinct from'in_progress'then perform public.inventory_cleaning_action(p_property,u.id,u.version,gen_random_uuid(),'start');end if;
   else
    if t.id is null then
     defaults:=public.task_setup(p_property)->'cleaning_defaults';
     perform public.task_create_advanced(p_property,gen_random_uuid(),jsonb_build_object('title','Clean room '||u.name,'kind','housekeeping','priority',coalesce(defaults->>'priority','normal'),'unit',u.id,'assignee',p_assignee,'target_minutes',defaults->>'target_minutes','checklist',coalesce(defaults->'checklist','["Inspect room cleanliness"]'::jsonb)));
    else perform public.task_action(p_property,t.id,t.version,gen_random_uuid(),'assign',jsonb_build_object('assignee',p_assignee));end if;
   end if;
   insert into public.inventory_events(tenant_id,property_id,entity,entity_id,action,actor_id,details)values(tenant,p_property,'rooms',u.id,'bulk_'||p_action,auth.uid(),jsonb_build_object('request',p_request,'assignee',p_assignee));
   results:=results||jsonb_build_array(jsonb_build_object('id',u.id,'name',u.name,'success',true));
  exception when sqlstate'22023'or sqlstate'40001'or sqlstate'42501'or check_violation then results:=results||jsonb_build_array(jsonb_build_object('id',item->>'id','name',item->>'name','success',false,'error',sqlerrm));
  end;
 end loop;
 result:=jsonb_build_object('rows',results,'updated',(select count(*)from jsonb_array_elements(results)x where(x->>'success')::boolean));
 insert into private.inventory_bulk_commands values(p_property,p_request,payload,result);return result;
end $$;
revoke all on function public.inventory_room_selection(uuid,jsonb),public.inventory_bulk_rooms(uuid,uuid,jsonb,text,uuid)from public,anon;
grant execute on function public.inventory_room_selection(uuid,jsonb),public.inventory_bulk_rooms(uuid,uuid,jsonb,text,uuid)to authenticated;
notify pgrst,'reload schema';
