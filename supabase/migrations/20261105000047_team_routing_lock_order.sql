-- Acquire the access lock before assignment-related parent rows and room locks.
create function private.staff_share(p_property uuid)returns void language plpgsql security definer set search_path=''as $$
declare business uuid;
begin
 select tenant_id into business from public.properties where id=p_property;
 if business is not null then perform pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended('staff-tenant:'||business::text,0));end if;
end $$;
revoke all on function private.staff_share(uuid)from public,anon,authenticated;

create or replace function public.task_create_advanced(p_property uuid,p_request uuid,p_details jsonb)returns uuid language plpgsql security definer set search_path='' as $$
declare tenant uuid;cmd public.task_commands;created_id uuid;recipient uuid;room uuid;dept uuid;target timestamptz;mins integer;labels jsonb;label text;position integer:=0;
begin
 perform private.staff_share(p_property);
 if not private.has_permission(p_property,'tasks.assign')then raise exception 'not permitted'using errcode='42501';end if;
 if p_request is null or p_details is null or jsonb_typeof(p_details)<>'object'then raise exception 'Reload this form.'using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('task-command:'||p_property::text||p_request::text,0));
 select * into cmd from public.task_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.action<>'create'or cmd.payload is distinct from p_details then raise exception 'Request ID already used.'using errcode='22023';end if;return cmd.result_id;end if;
 if length(trim(coalesce(p_details->>'title','')))not between 2 and 200 or length(coalesce(p_details->>'description',''))>2000 then raise exception 'Enter a title of 2–200 characters and details up to 2000.'using errcode='22023';end if;
 if coalesce(p_details->>'kind','')not in('housekeeping','maintenance','general')or coalesce(p_details->>'priority','')not in('low','normal','high','urgent')then raise exception 'Choose a valid work type and priority.'using errcode='22023';end if;
 select tenant_id into tenant from public.properties where id=p_property;
 recipient:=nullif(p_details->>'assignee','')::uuid;room:=nullif(p_details->>'unit','')::uuid;dept:=nullif(p_details->>'department','')::uuid;
 if recipient is not null then if not private.service_task_eligible(p_property,recipient)then raise exception 'Choose a teammate with task-write access.'using errcode='22023';end if;insert into public.property_memberships(tenant_id,property_id,user_id)values(tenant,p_property,recipient)on conflict do nothing;end if;
 if room is not null then perform 1 from public.accommodation_units where id=room and property_id=p_property and active for update;if not found then raise exception 'Choose an active room in this hotel.'using errcode='22023';end if;end if;
 if dept is not null and not exists(select 1 from public.departments where id=dept and property_id=p_property)then raise exception 'Choose a department in this hotel.'using errcode='22023';end if;
 mins:=nullif(p_details->>'target_minutes','')::integer;if mins is not null then if mins not between 1 and 10080 then raise exception 'Target must be 1–10080 minutes.'using errcode='22023';end if;target:=now()+make_interval(mins=>mins);end if;
 labels:=coalesce(p_details->'checklist','[]');if jsonb_typeof(labels)<>'array'or jsonb_array_length(labels)>20 then raise exception 'Use at most 20 checklist items.'using errcode='22023';end if;
 created_id:=public.create_task(p_property,trim(p_details->>'title'),p_details->>'kind',p_details->>'priority',recipient,room,target,p_details->>'description');
 update public.tasks set department_id=dept where id=created_id;
 for label in select jsonb_array_elements_text(labels)loop
 if length(trim(coalesce(label,'')))not between 1 and 160 then raise exception 'Checklist items must be 1–160 characters.'using errcode='22023';end if;
 insert into public.task_checklists(tenant_id,property_id,task_id,label,position)values(tenant,p_property,created_id,trim(label),position);position:=position+1;end loop;
 if room is not null and p_details->>'kind'='housekeeping'then update public.accommodation_units set housekeeping_status='dirty'where id=room;end if;
 insert into public.task_commands(tenant_id,property_id,task_id,request_id,action,payload,result_id)values(tenant,p_property,created_id,p_request,'create',p_details,created_id);return created_id;
end $$;

create or replace function public.service_catalog_save(p_property uuid,p_request uuid,p_catalog uuid,p_version int,p_details jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare tenant uuid;item public.service_catalog;cmd public.service_desk_commands;category uuid;service_id uuid;target uuid;department uuid;minutes int;kind text;
begin
 perform private.staff_share(p_property);
 if not private.has_permission(p_property,'staff.manage') then raise exception 'not permitted' using errcode='42501';end if;
 if p_request is null or p_details is null or jsonb_typeof(p_details)<>'object' then raise exception 'Reload this service form.' using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('service-command:'||p_property::text||p_request::text,0));
 select * into cmd from public.service_desk_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.action<>'catalog_save' or cmd.catalog_id is distinct from coalesce(p_catalog,cmd.result_id) or cmd.payload is distinct from p_details then raise exception 'Request ID already used for different details.' using errcode='22023';end if;return cmd.result_id;end if;
 select tenant_id into tenant from public.properties where public.properties.id=p_property for update;
 if length(trim(coalesce(p_details->>'name',''))) not between 2 and 120 or length(trim(coalesce(p_details->>'category',''))) not between 2 and 80 or length(coalesce(p_details->>'description',''))>500 then raise exception 'Check the service name, category, and description.' using errcode='22023';end if;
 if coalesce(p_details->>'priority','') not in ('low','normal','high','urgent') then raise exception 'Choose a valid priority.' using errcode='22023';end if;
 minutes:=nullif(p_details->>'target_minutes','')::int;if minutes is not null and minutes not between 1 and 10080 then raise exception 'Response targets must be 1–10080 minutes.' using errcode='22023';end if;
 kind:=coalesce(p_details->>'kind','none');if kind not in ('none','housekeeping','maintenance','general') then raise exception 'Choose a valid routing kind.' using errcode='22023';end if;
 if p_catalog is not null then select * into item from public.service_catalog where public.service_catalog.id=p_catalog and property_id=p_property for update;
  if not found then raise exception 'Service not found in this hotel.' using errcode='22023';end if;
  if item.version is distinct from p_version then raise exception 'This service changed. Refresh before saving.' using errcode='40001';end if;end if;
 if exists(select 1 from public.service_catalog where property_id=p_property and lower(trim(name))=lower(trim(p_details->>'name')) and public.service_catalog.id is distinct from p_catalog) then raise exception 'A service with this name already exists.' using errcode='23505';end if;
 target:=nullif(p_details->>'assignee','')::uuid;department:=nullif(p_details->>'department','')::uuid;
 if kind='none' then target:=null;department:=null;end if;
 if target is not null then if not private.service_task_eligible(p_property,target) then raise exception 'Choose a default assignee with task-write access to this hotel.' using errcode='22023';end if;
  insert into public.property_memberships(tenant_id,property_id,user_id)values(tenant,p_property,target)on conflict do nothing;end if;
 if department is not null and not exists(select 1 from public.departments where public.departments.id=department and property_id=p_property) then raise exception 'Department does not belong to this hotel.' using errcode='22023';end if;
 select public.service_categories.id into category from public.service_categories where property_id=p_property and lower(trim(name))=lower(trim(p_details->>'category')) limit 1;
 if category is null then insert into public.service_categories(tenant_id,property_id,name)values(tenant,p_property,trim(p_details->>'category'))returning public.service_categories.id into category;end if;
 if p_catalog is null then
  insert into public.service_catalog(tenant_id,property_id,category_id,name,description,default_priority,target_minutes,active)values(tenant,p_property,category,trim(p_details->>'name'),coalesce(p_details->>'description',''),p_details->>'priority',minutes,coalesce((p_details->>'active')::boolean,true))returning public.service_catalog.id into service_id;
 else update public.service_catalog set category_id=category,name=trim(p_details->>'name'),description=coalesce(p_details->>'description',''),default_priority=p_details->>'priority',target_minutes=minutes,active=coalesce((p_details->>'active')::boolean,true)where public.service_catalog.id=p_catalog returning public.service_catalog.id into service_id;end if;
 if kind='none' then delete from public.service_routing_rules where catalog_id=service_id;
 else insert into public.service_routing_rules(tenant_id,property_id,catalog_id,task_kind,department_id,default_assignee_id,sla_minutes)values(tenant,p_property,service_id,kind,department,target,minutes)
 on conflict(catalog_id)do update set task_kind=excluded.task_kind,department_id=excluded.department_id,default_assignee_id=excluded.default_assignee_id,sla_minutes=excluded.sla_minutes;end if;
 insert into public.service_desk_commands(tenant_id,property_id,request_id,catalog_id,action,payload,result_id,actor_id)values(tenant,p_property,p_request,service_id,'catalog_save',p_details,service_id,auth.uid());return service_id;
end $$;

create or replace function public.service_desk_action(p_property uuid,p_id uuid,p_version int,p_request uuid,p_action text,p_details jsonb default '{}') returns uuid
language plpgsql security definer set search_path='' as $$
declare g public.guest_requests;t public.tasks;cmd public.service_desk_commands;manager boolean;assigner boolean;worker boolean;id uuid;target uuid;mins int;next_priority text;deadline timestamptz;
begin
 perform private.staff_share(p_property);
 if not private.service_request_visible(p_id) then raise exception 'not permitted' using errcode='42501';end if;
 if p_request is null or p_details is null or jsonb_typeof(p_details)<>'object' then raise exception 'Reload this request and try again.' using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('service-command:'||p_property::text||p_request::text,0));
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('service-request:'||p_id::text,0));
 select * into cmd from public.service_desk_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.guest_request_id is distinct from p_id or cmd.action<>p_action or cmd.payload is distinct from p_details then raise exception 'Request ID already used for different details.' using errcode='22023';end if;return cmd.result_id;end if;
 select * into t from public.tasks where guest_request_id=p_id for update;
 select * into g from public.guest_requests where public.guest_requests.id=p_id and property_id=p_property for update;
 if not found then raise exception 'Request not found in this hotel.' using errcode='22023';end if;
 if p_action<>'comment' and g.version is distinct from p_version then raise exception 'This request changed. Refresh before continuing.' using errcode='40001';end if;
 manager:=private.has_permission(p_property,'guest_requests.manage');assigner:=private.has_permission(p_property,'tasks.assign');worker:=t.assignee_id=auth.uid() and private.has_permission(p_property,'tasks.write');id:=g.id;
 if p_action='comment' then
  if not(manager or coalesce(worker,false)) then raise exception 'not permitted' using errcode='42501';end if;
  if length(trim(coalesce(p_details->>'body',''))) not between 1 and 2000 then raise exception 'Write a comment of 1–2000 characters.' using errcode='22023';end if;
  insert into public.guest_request_comments(tenant_id,property_id,guest_request_id,author_id,body)values(g.tenant_id,p_property,g.id,auth.uid(),trim(p_details->>'body')) returning public.guest_request_comments.id into id;
 elsif p_action='feedback' then
  if not manager then raise exception 'not permitted' using errcode='42501';end if;
  if coalesce(p_details->>'rating','')!~'^[1-5]$' then raise exception 'Choose a rating from 1 to 5.' using errcode='22023';end if;
  perform public.record_guest_request_feedback(g.id,(p_details->>'rating')::int,p_details->>'comment');
  select public.guest_request_feedback.id into id from public.guest_request_feedback where guest_request_id=g.id;
 else
  if g.status not in ('new','in_progress') then raise exception 'This request is resolved. Create a follow-up for new work.' using errcode='22023';end if;
  if p_action='cancel' then
   if not manager then raise exception 'not permitted' using errcode='42501';end if;perform public.cancel_guest_request(g.id,p_details->>'reason');
  elsif p_action in ('start','complete') then
   if t.id is not null then
    if not(assigner or coalesce(worker,false)) then raise exception 'The assigned teammate must update the linked task. Request management does not grant task-write access.' using errcode='42501';end if;
    perform public.set_task_status(t.id,case when p_action='start' then 'in_progress' else 'done' end);
   else
    if not manager then raise exception 'not permitted' using errcode='42501';end if;
    if p_action='complete' then perform public.complete_guest_request(g.id);
    else if g.status<>'new' then raise exception 'Request is already in progress.' using errcode='22023';end if;update public.guest_requests set status='in_progress' where public.guest_requests.id=g.id;
     insert into public.guest_request_events(tenant_id,property_id,guest_request_id,event_type,actor_id,details)values(g.tenant_id,p_property,g.id,'status_changed',auth.uid(),jsonb_build_object('from',g.status,'to','in_progress'));end if;
   end if;
  elsif p_action='triage' then
   if not manager then raise exception 'not permitted' using errcode='42501';end if;
   next_priority:=coalesce(nullif(p_details->>'priority',''),g.priority);
   if next_priority not in ('low','normal','high','urgent') then raise exception 'Choose a valid priority.' using errcode='22023';end if;deadline:=g.due_at;
   if p_details->>'deadline'='clear' then deadline:=null;
   elsif p_details->>'deadline'='set' then mins:=(p_details->>'target_minutes')::int;if mins is null or mins not between 1 and 10080 then raise exception 'Response targets must be 1–10080 minutes.' using errcode='22023';end if;deadline:=now()+make_interval(mins=>mins);
   elsif coalesce(p_details->>'deadline','keep')<>'keep' then raise exception 'Choose a deadline action.' using errcode='22023';end if;
   update public.guest_requests set priority=next_priority,due_at=deadline where public.guest_requests.id=g.id;
   if t.id is not null then update public.tasks set priority=next_priority,due_at=deadline,updated_at=now() where public.tasks.id=t.id;end if;
   insert into public.guest_request_events(tenant_id,property_id,guest_request_id,event_type,actor_id,details)values(g.tenant_id,p_property,g.id,'triaged',auth.uid(),jsonb_build_object('priority',next_priority,'due_at',deadline));
  elsif p_action='assign' then
   if not assigner or t.id is null then raise exception 'not permitted' using errcode='42501';end if;
   target:=nullif(p_details->>'assignee','')::uuid;
   if target is not null then if not private.service_task_eligible(p_property,target) then raise exception 'Choose a teammate with task-write access to this hotel.' using errcode='22023';end if;
    insert into public.property_memberships(tenant_id,property_id,user_id)values(g.tenant_id,p_property,target)on conflict do nothing;end if;
   perform public.assign_task(t.id,target);
  elsif p_action='claim' then
   if t.id is null or not private.service_task_eligible(p_property,auth.uid()) then raise exception 'not permitted' using errcode='42501';end if;
   insert into public.property_memberships(tenant_id,property_id,user_id)values(g.tenant_id,p_property,auth.uid())on conflict do nothing;perform public.claim_task(t.id);
  elsif p_action='attach_task' then
   if not(manager and assigner) or t.id is not null then raise exception 'A manager can create one linked task for an unrouted request.' using errcode='42501';end if;
   if coalesce(p_details->>'kind','') not in ('housekeeping','maintenance','general') then raise exception 'Choose a task kind.' using errcode='22023';end if;
   insert into public.tasks(tenant_id,property_id,title,description,kind,priority,status,reservation_id,guest_request_id,due_at,created_by,started_at)
   values(g.tenant_id,p_property,g.title,g.notes,p_details->>'kind',g.priority,case when g.status='in_progress' then 'in_progress' else 'open' end,g.reservation_id,g.id,g.due_at,auth.uid(),case when g.status='in_progress' then now() end) returning public.tasks.id into id;
   update public.guest_requests set updated_at=now() where public.guest_requests.id=g.id;
   insert into public.task_events(tenant_id,property_id,task_id,event_type,actor_id,details)values(g.tenant_id,p_property,id,'created',auth.uid(),jsonb_build_object('guest_request_id',g.id));
   insert into public.guest_request_events(tenant_id,property_id,guest_request_id,event_type,actor_id,details)values(g.tenant_id,p_property,g.id,'task_created',auth.uid(),jsonb_build_object('task_id',id));
  else raise exception 'Unknown service action.' using errcode='22023';end if;
 end if;
 insert into public.service_desk_commands(tenant_id,property_id,request_id,guest_request_id,action,payload,result_id,actor_id)values(g.tenant_id,p_property,p_request,g.id,p_action,p_details,id,auth.uid());return id;
end $$;

create or replace function private.create_guest_request_core(p_property uuid,p_reservation uuid,p_catalog uuid,p_title text,p_notes text,p_source text,p_actor uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare r public.reservations;item public.service_catalog;rule public.service_routing_rules;unit_id uuid;unit_name text;title text;id uuid;task uuid;deadline timestamptz;
begin
 perform private.staff_share(p_property);
 select * into r from public.reservations where public.reservations.id=p_reservation and property_id=p_property;
 if not found or r.status not in ('confirmed','checked_in') then raise exception 'reservation is not active for this property' using errcode='22023';end if;
 if length(coalesce(p_title,''))>200 or length(coalesce(p_notes,''))>2000 then raise exception 'Request title or notes are too long.' using errcode='22023';end if;
 if p_catalog is not null then
  select * into item from public.service_catalog where public.service_catalog.id=p_catalog and property_id=p_property and active;
  if not found then raise exception 'unknown or inactive service' using errcode='22023';end if;
  select * into rule from public.service_routing_rules where catalog_id=p_catalog;
 end if;
 title:=coalesce(nullif(trim(p_title),''),item.name);if title is null then raise exception 'title or service required' using errcode='22023';end if;
 if coalesce(item.target_minutes,rule.sla_minutes) is not null then deadline:=now()+make_interval(mins=>coalesce(item.target_minutes,rule.sla_minutes));end if;
 select h.unit_id,u.name into unit_id,unit_name from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.reservation_id=r.id and h.active limit 1;
 insert into public.guest_requests(tenant_id,property_id,reservation_id,catalog_id,title,notes,priority,source,unit_id,created_by,due_at)
 values(r.tenant_id,p_property,r.id,p_catalog,title,p_notes,coalesce(item.default_priority,'normal'),p_source,unit_id,p_actor,deadline) returning public.guest_requests.id into id;
 insert into public.guest_request_events(tenant_id,property_id,guest_request_id,event_type,actor_id,details)values(r.tenant_id,p_property,id,'created',p_actor,jsonb_build_object('source',p_source));
 if rule.id is not null then
  insert into public.tasks(tenant_id,property_id,title,description,kind,priority,assignee_id,department_id,reservation_id,guest_request_id,due_at,created_by)
  values(r.tenant_id,p_property,title||coalesce(' (unit '||unit_name||')',''),p_notes,rule.task_kind,coalesce(item.default_priority,'normal'),rule.default_assignee_id,rule.department_id,r.id,id,deadline,p_actor) returning public.tasks.id into task;
  insert into public.task_events(tenant_id,property_id,task_id,event_type,actor_id,details)values(r.tenant_id,p_property,task,'created',p_actor,jsonb_build_object('guest_request_id',id));
  insert into public.guest_request_events(tenant_id,property_id,guest_request_id,event_type,actor_id,details)values(r.tenant_id,p_property,id,'task_created',p_actor,jsonb_build_object('task_id',task));
 end if;return id;
end $$;

create or replace function private.staff_assignment_guard()returns trigger language plpgsql security definer set search_path=''as $$
declare target uuid;
begin
 if not exists(select 1 from public.tenants where id=new.tenant_id)then return new;end if;
 perform pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended('staff-tenant:'||new.tenant_id::text,0));
 if tg_table_name='tasks'then
 target:=new.assignee_id;
 if target is not null and new.status in('open','in_progress')and auth.uid()is not null and exists(select 1 from public.property_memberships where property_id=new.property_id and user_id=target)and not private.service_task_eligible(new.property_id,target)then raise exception 'Choose a teammate with task-work access to this hotel.'using errcode='22023';end if;
 elsif tg_table_name='conversations'then target:=new.assigned_to;
 if target is not null and new.status='open'and auth.uid()is not null and exists(select 1 from public.property_memberships where property_id=new.property_id and user_id=target)and not private.inbox_eligible_user(new.property_id,target)then raise exception 'Choose a teammate with inbox access to this hotel.'using errcode='22023';end if;
 else target:=new.default_assignee_id;
 if target is not null and auth.uid()is not null and not private.service_task_eligible(new.property_id,target)then raise exception 'Choose a default assignee with task-work access.'using errcode='22023';end if;
 end if;return new;
end $$;
create trigger staff_assignment_guard before insert or update of default_assignee_id on public.service_routing_rules for each row execute function private.staff_assignment_guard();
