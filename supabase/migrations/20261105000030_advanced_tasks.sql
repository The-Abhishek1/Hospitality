-- Operational task workspace: versioned commands, checklists and scoped read models.
alter table public.tasks add column version integer not null default 1;
create function private.task_record_version() returns trigger language plpgsql set search_path='' as $$
begin new.version:=old.version+1;new.updated_at:=now();return new;end $$;
revoke all on function private.task_record_version()from public,anon,authenticated;
create trigger task_record_version before update on public.tasks for each row execute function private.task_record_version();
create table public.task_commands(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,property_id uuid not null,task_id uuid not null,
 request_id uuid not null,action text not null,payload jsonb not null,result_id uuid not null,created_at timestamptz not null default now(),
 unique(property_id,request_id),foreign key(task_id,property_id)references public.tasks(id,property_id)on delete cascade,
 foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade
);
alter table public.task_commands enable row level security;
create policy task_commands_read on public.task_commands for select to authenticated using(private.has_permission(property_id,'tasks.assign'));
create function private.task_visible(p_id uuid)returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.tasks t where t.id=p_id and private.has_property_access(t.property_id)and
 (private.has_permission(t.property_id,'tasks.assign')or(t.assignee_id=auth.uid()and private.has_permission(t.property_id,'tasks.read'))or(t.assignee_id is null and private.has_permission(t.property_id,'tasks.read')and private.has_permission(t.property_id,'tasks.write'))))
$$;
revoke all on function private.task_visible(uuid)from public,anon;
grant execute on function private.task_visible(uuid)to authenticated;
drop policy tasks_select on public.tasks;
create policy tasks_select on public.tasks for select to authenticated using(private.task_visible(id));
-- Checklist writes go through the locked task command; workers cannot rename/reparent checklist rows.
drop policy checklists_manage on public.task_checklists;
drop policy checklists_toggle on public.task_checklists;
drop policy comments_insert on public.task_comments;
create policy comments_insert on public.task_comments for insert to authenticated with check(
 author_id=auth.uid()and length(trim(body))between 1 and 2000 and exists(select 1 from public.tasks t where t.id=task_id and t.property_id=task_comments.property_id and t.tenant_id=task_comments.tenant_id and
 (private.has_permission(t.property_id,'tasks.assign')or(t.assignee_id=auth.uid()and private.has_permission(t.property_id,'tasks.write')))));

create function private.task_completion_guard()returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='done'and old.status<>'done'and exists(select 1 from public.task_checklists where task_id=old.id and not done)then
 raise exception 'Finish every checklist item before completing this task.'using errcode='22023';end if;
 return new;
end $$;
revoke all on function private.task_completion_guard()from public,anon,authenticated;
create trigger task_completion_guard before update of status on public.tasks for each row execute function private.task_completion_guard();

create or replace function public.set_task_status(p_id uuid,p_status text)returns void language plpgsql security definer set search_path='' as $$
declare t public.tasks;manager boolean;worker boolean;
begin
 t:=private.lock_task(p_id);manager:=private.has_permission(t.property_id,'tasks.assign');worker:=coalesce(t.assignee_id=auth.uid(),false)and private.has_permission(t.property_id,'tasks.write');
 if not(manager or worker)then raise exception 'not permitted'using errcode='42501';end if;
 if(t.status,p_status)not in(('open','in_progress'),('open','done'),('in_progress','done'),('in_progress','open'),('open','cancelled'),('in_progress','cancelled'),('done','open'),('cancelled','open'))then raise exception 'invalid transition % -> %',t.status,p_status using errcode='22023';end if;
 if(p_status='cancelled'or t.status in('done','cancelled'))and not manager then raise exception 'not permitted'using errcode='42501';end if;
 update public.tasks set status=p_status,started_at=case when p_status='open'and t.status in('done','cancelled')then null when p_status='in_progress'then coalesce(started_at,now())else started_at end,
 completed_at=case when p_status='done'then now()end where id=p_id;
 if t.kind='housekeeping'and t.unit_id is not null then update public.accommodation_units set housekeeping_status=case p_status when 'in_progress'then 'in_progress'when 'done'then 'clean'when 'open'then 'dirty'else housekeeping_status end where id=t.unit_id;end if;
 insert into public.task_events(tenant_id,property_id,task_id,event_type,actor_id,details)values(t.tenant_id,t.property_id,p_id,'status_changed',auth.uid(),jsonb_build_object('from',t.status,'to',p_status));
end $$;

create function public.task_create_advanced(p_property uuid,p_request uuid,p_details jsonb)returns uuid language plpgsql security definer set search_path='' as $$
declare tenant uuid;cmd public.task_commands;created_id uuid;recipient uuid;room uuid;dept uuid;target timestamptz;mins integer;labels jsonb;label text;position integer:=0;
begin
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
 if room is not null and not exists(select 1 from public.accommodation_units where id=room and property_id=p_property and active)then raise exception 'Choose an active room in this hotel.'using errcode='22023';end if;
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

create function public.task_action(p_property uuid,p_id uuid,p_version integer,p_request uuid,p_action text,p_details jsonb default '{}')returns uuid language plpgsql security definer set search_path='' as $$
declare t public.tasks;cmd public.task_commands;manager boolean;worker boolean;recipient uuid;item uuid;result_id uuid;mins integer;target timestamptz;label text;pos integer;
begin
 if not private.task_visible(p_id)then raise exception 'not permitted'using errcode='42501';end if;
 if p_request is null or p_details is null or jsonb_typeof(p_details)<>'object'then raise exception 'Reload this task.'using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('task-command:'||p_property::text||p_request::text,0));
 t:=private.lock_task(p_id);if t.property_id<>p_property then raise exception 'Task not found in this hotel.'using errcode='22023';end if;
 select * into cmd from public.task_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.task_id<>p_id or cmd.action<>p_action or cmd.payload is distinct from p_details then raise exception 'Request ID already used.'using errcode='22023';end if;return cmd.result_id;end if;
 if p_action<>'comment'and t.version is distinct from p_version then raise exception 'This task changed. Refresh and review it before continuing.'using errcode='40001';end if;
 manager:=private.has_permission(p_property,'tasks.assign');worker:=coalesce(t.assignee_id=auth.uid(),false)and private.has_permission(p_property,'tasks.write');result_id:=t.id;
 if p_action='comment'then
 if not(manager or worker)then raise exception 'not permitted'using errcode='42501';end if;
 if length(trim(coalesce(p_details->>'body','')))not between 1 and 2000 then raise exception 'Write a comment of 1–2000 characters.'using errcode='22023';end if;
 insert into public.task_comments(tenant_id,property_id,task_id,author_id,body)values(t.tenant_id,p_property,t.id,auth.uid(),trim(p_details->>'body'))returning id into result_id;
 elsif p_action='status'then
 if p_details->>'status'in('cancelled','open')and(t.status in('done','cancelled')or p_details->>'status'='cancelled')and length(trim(coalesce(p_details->>'reason','')))not between 3 and 500 then raise exception 'Give a reason of 3–500 characters.'using errcode='22023';end if;
 perform public.set_task_status(t.id,p_details->>'status');
 if nullif(trim(p_details->>'reason'),'')is not null then insert into public.task_events(tenant_id,property_id,task_id,event_type,actor_id,details)values(t.tenant_id,p_property,t.id,'resolution_note',auth.uid(),jsonb_build_object('reason',left(trim(p_details->>'reason'),500)));end if;
 elsif p_action='claim'then
 insert into public.property_memberships(tenant_id,property_id,user_id)select t.tenant_id,p_property,auth.uid()where private.service_task_eligible(p_property,auth.uid())on conflict do nothing;perform public.claim_task(t.id);
 elsif p_action='assign'then
 if not manager then raise exception 'not permitted'using errcode='42501';end if;
 if t.status not in('open','in_progress')then raise exception 'Reopen this task before assigning it.'using errcode='22023';end if;
 recipient:=nullif(p_details->>'assignee','')::uuid;if recipient is not null then if not private.service_task_eligible(p_property,recipient)then raise exception 'Choose a teammate with task-write access.'using errcode='22023';end if;insert into public.property_memberships(tenant_id,property_id,user_id)values(t.tenant_id,p_property,recipient)on conflict do nothing;end if;perform public.assign_task(t.id,recipient);
 elsif p_action='triage'then
 if not manager then raise exception 'not permitted'using errcode='42501';end if;
 if t.status not in('open','in_progress')then raise exception 'Task is already resolved.'using errcode='22023';end if;
 if coalesce(p_details->>'priority','')not in('low','normal','high','urgent')then raise exception 'Choose a valid priority.'using errcode='22023';end if;target:=t.due_at;
 if p_details->>'deadline'='clear'then target:=null;elsif p_details->>'deadline'='set'then mins:=(p_details->>'target_minutes')::integer;if mins is null or mins not between 1 and 10080 then raise exception 'Target must be 1–10080 minutes.'using errcode='22023';end if;target:=now()+make_interval(mins=>mins);elsif coalesce(p_details->>'deadline','keep')<>'keep'then raise exception 'Choose a target action.'using errcode='22023';end if;
 update public.tasks set priority=p_details->>'priority',due_at=target where id=t.id;
 insert into public.task_events(tenant_id,property_id,task_id,event_type,actor_id,details)values(t.tenant_id,p_property,t.id,'triaged',auth.uid(),jsonb_build_object('priority',p_details->>'priority','due_at',target));
 elsif p_action in('check','add_check','remove_check')then
 if not(manager or worker)then raise exception 'not permitted'using errcode='42501';end if;
 if t.status not in('open','in_progress')then raise exception 'Reopen the task before changing its checklist.'using errcode='22023';end if;
 if p_action='check'then
 item:=(p_details->>'item')::uuid;update public.task_checklists set done=(p_details->>'done')::boolean where id=item and task_id=t.id and p_details->>'done'in('true','false');if not found then raise exception 'Checklist item not found.'using errcode='22023';end if;
 else
 if not manager then raise exception 'not permitted'using errcode='42501';end if;
 if p_action='add_check'then
 label:=trim(coalesce(p_details->>'label',''));if length(label)not between 1 and 160 or(select count(*)from public.task_checklists where task_id=t.id)>=20 then raise exception 'Use up to 20 items, each 1–160 characters.'using errcode='22023';end if;
 select coalesce(max(position),-1)+1 into pos from public.task_checklists where task_id=t.id;
 insert into public.task_checklists(tenant_id,property_id,task_id,label,position)values(t.tenant_id,p_property,t.id,label,pos)returning id into item;
 else item:=(p_details->>'item')::uuid;delete from public.task_checklists where id=item and task_id=t.id;if not found then raise exception 'Checklist item not found.'using errcode='22023';end if;end if;end if;
 update public.tasks set updated_at=now()where id=t.id;
 insert into public.task_events(tenant_id,property_id,task_id,event_type,actor_id,details)values(t.tenant_id,p_property,t.id,'checklist_updated',auth.uid(),jsonb_build_object('action',p_action,'item',item,'done',p_details->>'done'));
 else raise exception 'Unknown task action.'using errcode='22023';end if;
 insert into public.task_commands(tenant_id,property_id,task_id,request_id,action,payload,result_id)values(t.tenant_id,p_property,t.id,p_request,p_action,p_details,result_id);return result_id;
end $$;
revoke all on function public.task_create_advanced(uuid,uuid,jsonb),public.task_action(uuid,uuid,integer,uuid,text,jsonb)from public,anon;
grant execute on function public.task_create_advanced(uuid,uuid,jsonb),public.task_action(uuid,uuid,integer,uuid,text,jsonb)to authenticated;
