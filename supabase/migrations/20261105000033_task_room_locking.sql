-- Acquire room locks before task locks, matching checkout and new room-cleaning creation.
create or replace function private.lock_task(p_id uuid)returns public.tasks language plpgsql security definer set search_path='' as $$
declare t public.tasks;linked uuid;room uuid;work_kind text;
begin
 select guest_request_id,unit_id,kind into linked,room,work_kind from public.tasks where id=p_id;
 if linked is not null then perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('service-request:'||linked::text,0));end if;
 if room is not null and work_kind='housekeeping'then perform 1 from public.accommodation_units where id=room for update;end if;
 select * into t from public.tasks where id=p_id for update;
 if not found then raise exception 'not permitted'using errcode='42501';end if;return t;
end $$;

create or replace function public.task_create_advanced(p_property uuid,p_request uuid,p_details jsonb)returns uuid language plpgsql security definer set search_path='' as $$
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
