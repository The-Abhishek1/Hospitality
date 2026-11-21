alter table public.guest_requests add column due_at timestamptz,add column version integer not null default 1;
alter table public.service_catalog add column description text not null default '' check(length(description)<=500),
 add column target_minutes int check(target_minutes between 1 and 10080),add column version integer not null default 1;
create unique index tasks_one_per_guest_request on public.tasks(guest_request_id) where guest_request_id is not null;
update public.guest_requests g set due_at=t.due_at from public.tasks t where t.guest_request_id=g.id;
alter table public.guest_request_feedback add column recorded_via text not null default 'legacy' check(recorded_via in ('guest','staff_reported','legacy'));
alter table public.guest_request_feedback alter column recorded_via set default 'guest';
create function private.service_record_version() returns trigger language plpgsql set search_path='' as $$
begin new.version:=old.version+1;if tg_table_name='guest_requests' then new.updated_at:=now();end if;return new;end $$;
revoke all on function private.service_record_version() from public,anon,authenticated;
create trigger guest_requests_version before update on public.guest_requests for each row execute function private.service_record_version();
create trigger service_catalog_version before update on public.service_catalog for each row execute function private.service_record_version();

create function private.service_request_visible(p_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.guest_requests g where g.id=p_id and private.has_property_access(g.property_id) and
 (private.has_permission(g.property_id,'guest_requests.read') or private.has_permission(g.property_id,'guest_requests.manage') or
 exists(select 1 from public.tasks t where t.guest_request_id=g.id and t.assignee_id=auth.uid())))
$$;
create function private.service_task_eligible(p_property uuid,p_user uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.properties p join public.tenant_memberships m on m.tenant_id=p.tenant_id where p.id=p_property and m.user_id=p_user and
 (m.role in ('owner','admin') or exists(select 1 from public.user_roles ur join public.role_permissions rp on rp.role_id=ur.role_id where ur.property_id=p_property and ur.user_id=p_user and rp.permission_key='tasks.write')))
$$;
create table public.guest_request_comments(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,property_id uuid not null,guest_request_id uuid not null,
 author_id uuid not null references public.profiles(id),body text not null check(length(trim(body)) between 1 and 2000),created_at timestamptz not null default now(),
 foreign key(guest_request_id,property_id) references public.guest_requests(id,property_id) on delete cascade,
 foreign key(property_id,tenant_id) references public.properties(id,tenant_id) on delete cascade
);
create table public.service_desk_commands(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,property_id uuid not null,request_id uuid not null,
 guest_request_id uuid,catalog_id uuid,action text not null,payload jsonb not null,result_id uuid,actor_id uuid references public.profiles(id),created_at timestamptz not null default now(),
 unique(property_id,request_id),foreign key(guest_request_id,property_id) references public.guest_requests(id,property_id) on delete cascade,
 foreign key(catalog_id,property_id) references public.service_catalog(id,property_id) on delete cascade,
 foreign key(property_id,tenant_id) references public.properties(id,tenant_id) on delete cascade
);
alter table public.guest_request_comments enable row level security;
alter table public.service_desk_commands enable row level security;
create policy request_comments_visible on public.guest_request_comments for select to authenticated using(private.service_request_visible(guest_request_id));
create policy service_commands_managers on public.service_desk_commands for select to authenticated using(private.has_permission(property_id,'guest_requests.manage') or private.has_permission(property_id,'staff.manage'));
grant execute on function private.service_request_visible(uuid) to authenticated;
revoke all on function private.service_request_visible(uuid) from public,anon;
revoke all on function private.service_task_eligible(uuid,uuid) from public,anon,authenticated;

-- All authenticated task/request APIs serialize linked work on one request key.
create or replace function private.lock_task(p_id uuid) returns public.tasks
language plpgsql security definer set search_path='' as $$
declare t public.tasks;linked uuid;
begin
 select guest_request_id into linked from public.tasks where id=p_id;
 if linked is not null then perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('service-request:'||linked::text,0));end if;
 select * into t from public.tasks where id=p_id for update;
 if not found then raise exception 'not permitted' using errcode='42501';end if;return t;
end $$;
create or replace function private.lock_guest_request(p_id uuid) returns public.guest_requests
language plpgsql security definer set search_path='' as $$
declare g public.guest_requests;
begin
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('service-request:'||p_id::text,0));
 perform 1 from public.tasks where guest_request_id=p_id order by id for update;
 select * into g from public.guest_requests where id=p_id for update;
 if not found or not private.has_permission(g.property_id,'guest_requests.manage') then raise exception 'not permitted' using errcode='42501';end if;return g;
end $$;

create or replace function private.create_guest_request_core(p_property uuid,p_reservation uuid,p_catalog uuid,p_title text,p_notes text,p_source text,p_actor uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare r public.reservations;item public.service_catalog;rule public.service_routing_rules;unit_id uuid;unit_name text;title text;id uuid;task uuid;deadline timestamptz;
begin
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

create or replace function private.sync_request_from_task() returns trigger
language plpgsql security definer set search_path='' as $$
declare g public.guest_requests;new_status text;
begin
 if new.guest_request_id is null then return new;end if;
 if (new.status,new.assignee_id,new.priority,new.due_at) is not distinct from (old.status,old.assignee_id,old.priority,old.due_at) then return new;end if;
 select * into g from public.guest_requests where id=new.guest_request_id for update;
 if old.status in ('done','cancelled') and new.status='open' and exists(select 1 from public.guest_request_feedback where guest_request_id=g.id) then raise exception 'This request already has feedback. Create a follow-up request instead of reopening it.' using errcode='22023';end if;
 new_status:=case new.status when 'in_progress' then 'in_progress' when 'done' then 'completed' when 'cancelled' then 'cancelled' else 'new' end;
 if (g.status,g.priority,g.due_at) is distinct from (new_status,new.priority,new.due_at) or new.assignee_id is distinct from old.assignee_id then
  update public.guest_requests set status=new_status,priority=new.priority,due_at=new.due_at,completed_at=case when new_status='completed' then coalesce(g.completed_at,now()) else null end where id=g.id;
  insert into public.guest_request_events(tenant_id,property_id,guest_request_id,event_type,actor_id,details)
  values(new.tenant_id,new.property_id,g.id,case when g.status<>new_status then 'status_changed' else 'task_updated' end,auth.uid(),jsonb_build_object('from',g.status,'to',new_status,'via_task',new.id,'assignee_id',new.assignee_id,'priority',new.priority,'due_at',new.due_at));
 end if;return new;
end $$;
drop trigger tasks_sync_guest_request on public.tasks;
create trigger tasks_sync_guest_request after update of status,assignee_id,priority,due_at on public.tasks for each row execute function private.sync_request_from_task();

create or replace function public.cancel_guest_request(p_id uuid,p_reason text default null) returns void
language plpgsql security definer set search_path='' as $$
declare g public.guest_requests;
begin
 g:=private.lock_guest_request(p_id);
 if g.status not in ('new','in_progress') then raise exception 'Request is already resolved.' using errcode='22023';end if;
 if length(trim(coalesce(p_reason,''))) not between 3 and 500 then raise exception 'Enter a cancellation reason (3–500 characters).' using errcode='22023';end if;
 update public.guest_requests set status='cancelled',completed_at=null where id=g.id;
 update public.tasks set status='cancelled',updated_at=now(),completed_at=null where guest_request_id=g.id and status in ('open','in_progress');
 insert into public.guest_request_events(tenant_id,property_id,guest_request_id,event_type,actor_id,details)values(g.tenant_id,g.property_id,g.id,'cancelled',auth.uid(),jsonb_build_object('reason',trim(p_reason)));
end $$;
create or replace function public.record_guest_request_feedback(p_id uuid,p_rating int,p_comment text default null) returns void
language plpgsql security definer set search_path='' as $$
declare g public.guest_requests;
begin
 g:=private.lock_guest_request(p_id);if g.status<>'completed' then raise exception 'Feedback requires a completed request.' using errcode='22023';end if;
 if length(coalesce(p_comment,''))>1000 then raise exception 'Feedback comments must be 1000 characters or fewer.' using errcode='22023';end if;
 insert into public.guest_request_feedback(tenant_id,property_id,guest_request_id,rating,comment,recorded_via)values(g.tenant_id,g.property_id,g.id,p_rating,p_comment,'staff_reported');
end $$;

create function public.service_desk_create(p_property uuid,p_request uuid,p_details jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare cmd public.service_desk_commands;created_id uuid;g public.guest_requests;next_priority text;minutes int;
begin
 if not private.has_permission(p_property,'guest_requests.manage') then raise exception 'not permitted' using errcode='42501';end if;
 if p_request is null or p_details is null or jsonb_typeof(p_details)<>'object' then raise exception 'Reload the request form and try again.' using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('service-command:'||p_property::text||p_request::text,0));
 select * into cmd from public.service_desk_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.action<>'create' or cmd.payload is distinct from p_details then raise exception 'Request ID was already used for different details.' using errcode='22023';end if;return cmd.result_id;end if;
 next_priority:=nullif(p_details->>'priority','');if next_priority is not null and next_priority not in ('low','normal','high','urgent') then raise exception 'Choose a valid priority.' using errcode='22023';end if;
 minutes:=nullif(p_details->>'target_minutes','')::int;if minutes is not null and minutes not between 1 and 10080 then raise exception 'Response targets must be 1–10080 minutes.' using errcode='22023';end if;
 created_id:=private.create_guest_request_core(p_property,(p_details->>'reservation_id')::uuid,nullif(p_details->>'catalog_id','')::uuid,p_details->>'title',p_details->>'notes','staff',auth.uid());
 select * into g from public.guest_requests where public.guest_requests.id=created_id;
 if next_priority is distinct from g.priority and next_priority is not null then update public.guest_requests set priority=next_priority where public.guest_requests.id=created_id;end if;
 if minutes is not null then update public.guest_requests set due_at=now()+make_interval(mins=>minutes) where public.guest_requests.id=created_id;end if;
 select * into g from public.guest_requests where public.guest_requests.id=created_id;
 update public.tasks set priority=g.priority,due_at=g.due_at where guest_request_id=created_id and (public.tasks.priority,public.tasks.due_at) is distinct from (g.priority,g.due_at);
 insert into public.service_desk_commands(tenant_id,property_id,request_id,guest_request_id,action,payload,result_id,actor_id)values(g.tenant_id,p_property,p_request,g.id,'create',p_details,g.id,auth.uid());return g.id;
end $$;

create function public.service_desk_action(p_property uuid,p_id uuid,p_version int,p_request uuid,p_action text,p_details jsonb default '{}') returns uuid
language plpgsql security definer set search_path='' as $$
declare g public.guest_requests;t public.tasks;cmd public.service_desk_commands;manager boolean;assigner boolean;worker boolean;id uuid;target uuid;mins int;next_priority text;deadline timestamptz;
begin
 if not private.service_request_visible(p_id) then raise exception 'not permitted' using errcode='42501';end if;
 if p_request is null or p_details is null or jsonb_typeof(p_details)<>'object' then raise exception 'Reload this request and try again.' using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('service-command:'||p_property::text||p_request::text,0));
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('service-request:'||p_id::text,0));
 select * into cmd from public.service_desk_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.guest_request_id is distinct from p_id or cmd.action<>p_action or cmd.payload is distinct from p_details then raise exception 'Request ID already used for different details.' using errcode='22023';end if;return cmd.result_id;end if;
 select * into t from public.tasks where guest_request_id=p_id for update;
 select * into g from public.guest_requests where public.guest_requests.id=p_id and property_id=p_property for update;
 if not found then raise exception 'Request not found in this hotel.' using errcode='22023';end if;
 if g.version is distinct from p_version then raise exception 'This request changed. Refresh before continuing.' using errcode='40001';end if;
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

create function public.service_catalog_save(p_property uuid,p_request uuid,p_catalog uuid,p_version int,p_details jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare tenant uuid;item public.service_catalog;cmd public.service_desk_commands;category uuid;service_id uuid;target uuid;department uuid;minutes int;kind text;
begin
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
revoke all on function public.service_desk_create(uuid,uuid,jsonb),public.service_desk_action(uuid,uuid,int,uuid,text,jsonb),public.service_catalog_save(uuid,uuid,uuid,int,jsonb) from public,anon;
grant execute on function public.service_desk_create(uuid,uuid,jsonb),public.service_desk_action(uuid,uuid,int,uuid,text,jsonb),public.service_catalog_save(uuid,uuid,uuid,int,jsonb) to authenticated;
