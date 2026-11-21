-- Append-only comments survive task version changes; feedback shares request locks.
create or replace function public.service_desk_action(p_property uuid,p_id uuid,p_version int,p_request uuid,p_action text,p_details jsonb default '{}') returns uuid
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

create or replace function public.portal_submit_feedback(p_token text, p_request uuid, p_rating int, p_comment text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.reservations; q public.guest_requests;
begin
  r := private.portal_reservation(p_token);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('service-request:'||p_request::text,0));
  select * into q from public.guest_requests where id = p_request and reservation_id = r.id for update;   -- scoped to this stay
  if not found then raise exception 'request not found' using errcode = '22023'; end if;
  if q.status <> 'completed' then raise exception 'feedback is only collected for completed requests' using errcode = '22023'; end if;
  insert into public.guest_request_feedback (tenant_id, property_id, guest_request_id, rating, comment, recorded_via)
  values (q.tenant_id, q.property_id, q.id, p_rating, left(p_comment, 1000), 'guest');
end $$;
