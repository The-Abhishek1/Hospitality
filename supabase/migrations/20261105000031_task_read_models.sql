create function private.task_rows(p_property uuid)returns table(
 id uuid,version integer,title text,description text,kind text,status text,priority text,assignee_id uuid,assignee_name text,department_id uuid,department_name text,
 unit_id uuid,room text,housekeeping_status text,reservation_id uuid,guest_request_id uuid,due_at timestamptz,created_at timestamptz,started_at timestamptz,completed_at timestamptz,check_total bigint,check_done bigint)
language sql stable security definer set search_path='' as $$
 select t.id,t.version,t.title,t.description,t.kind,t.status,t.priority,t.assignee_id,coalesce(pr.full_name,pr.email),t.department_id,d.name,t.unit_id,u.name,u.housekeeping_status,t.reservation_id,t.guest_request_id,t.due_at,t.created_at,t.started_at,t.completed_at,
 (select count(*)from public.task_checklists c where c.task_id=t.id),(select count(*)from public.task_checklists c where c.task_id=t.id and c.done)
 from public.tasks t left join public.profiles pr on pr.id=t.assignee_id left join public.departments d on d.id=t.department_id left join public.accommodation_units u on u.id=t.unit_id
 where t.property_id=p_property and private.task_visible(t.id)
$$;
revoke all on function private.task_rows(uuid)from public,anon,authenticated;
create function public.task_workspace(p_property uuid,p_filters jsonb default '{}')returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;rooms jsonb;prop public.properties;day date;pg integer:=greatest(1,least(100000,coalesce((p_filters->>'page')::integer,1)));rp integer:=greatest(1,least(100000,coalesce((p_filters->>'room_page')::integer,1)));query text:=left(trim(coalesce(p_filters->>'q','')),100);view text:=coalesce(p_filters->>'view','active');
begin
 if not private.has_permission(p_property,'tasks.read')then raise exception 'not permitted'using errcode='42501';end if;
 select * into prop from public.properties where id=p_property;day:=(now()at time zone prop.timezone)::date;
 with all_tasks as materialized(select * from private.task_rows(p_property)),filtered as materialized(select * from all_tasks t where
 (query=''or strpos(lower(concat_ws(' ',t.title,t.room,t.assignee_name,t.department_name,t.id::text)),lower(query))>0)
 and(coalesce(p_filters->>'kind','')=''or t.kind=p_filters->>'kind')and(coalesce(p_filters->>'priority','')=''or t.priority=p_filters->>'priority')
 and(case view when 'active'then t.status in('open','in_progress')when 'mine'then t.assignee_id=auth.uid()and t.status in('open','in_progress')when 'unassigned'then t.assignee_id is null and t.status='open'when 'overdue'then t.status in('open','in_progress')and t.due_at<now()when 'done'then t.status='done'when 'cancelled'then t.status='cancelled'else true end))
 select jsonb_build_object('total',(select count(*)from filtered),'page',pg,'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select * from filtered order by
 case when coalesce(p_filters->>'sort','priority')='priority'then case priority when 'urgent'then 0 when 'high'then 1 when 'normal'then 2 else 3 end else 0 end,
 case when coalesce(p_filters->>'sort','priority')in('priority','deadline')then due_at end asc nulls last,created_at desc,id desc limit 20 offset(pg-1)*20)x),'[]'::jsonb),
 'stats',jsonb_build_object('active',(select count(*)from all_tasks where status in('open','in_progress')),'mine',(select count(*)from all_tasks where assignee_id=auth.uid()and status in('open','in_progress')),'unassigned',(select count(*)from all_tasks where assignee_id is null and status='open'),'overdue',(select count(*)from all_tasks where status in('open','in_progress')and due_at<now()),'done_today',(select count(*)from all_tasks where status='done'and(completed_at at time zone prop.timezone)::date=day)))into result;
 with room_rows as materialized(select u.id,u.name,ty.name as type_name,u.housekeeping_status,
 exists(select 1 from public.unit_holds h join public.reservations r on r.id=h.reservation_id where h.unit_id=u.id and h.active and r.status='checked_in')as occupied,
 exists(select 1 from public.unit_holds h join public.reservations r on r.id=h.reservation_id where h.unit_id=u.id and h.active and r.status='confirmed'and r.check_in=day)as arrival_today,
 (select t.id from public.tasks t where t.unit_id=u.id and t.kind='housekeeping'and t.status in('open','in_progress')and private.task_visible(t.id))as task_id,
 exists(select 1 from public.tasks t where t.unit_id=u.id and t.kind='housekeeping'and t.status in('open','in_progress'))as has_cleaning_task
 from public.accommodation_units u join public.accommodation_types ty on ty.id=u.type_id where u.property_id=p_property and u.active),filtered_rooms as materialized(select * from room_rows r where
 (coalesce(p_filters->>'room_q','')=''or strpos(lower(r.name||' '||r.type_name),lower(left(p_filters->>'room_q',100)))>0)
 and(case coalesce(p_filters->>'room_state','all')when 'attention'then r.housekeeping_status<>'clean'when 'arrival'then r.arrival_today and r.housekeeping_status<>'clean'when 'unallocated'then r.housekeeping_status<>'clean'and not r.has_cleaning_task when 'clean'then r.housekeeping_status='clean'else true end))
 select jsonb_build_object('room_page',rp,'room_total',(select count(*)from filtered_rooms),'rooms',coalesce((select jsonb_agg(to_jsonb(x))from(select * from filtered_rooms order by arrival_today desc,case housekeeping_status when 'dirty'then 0 when 'in_progress'then 1 else 2 end,name,id limit 12 offset(rp-1)*12)x),'[]'::jsonb),
 'room_stats',jsonb_build_object('total',(select count(*)from room_rows),'clean',(select count(*)from room_rows where housekeeping_status='clean'),'dirty',(select count(*)from room_rows where housekeeping_status='dirty'),'cleaning',(select count(*)from room_rows where housekeeping_status='in_progress'),'arrival_attention',(select count(*)from room_rows where arrival_today and housekeeping_status<>'clean')))into rooms;
 return result||rooms||jsonb_build_object('user_id',auth.uid(),'timezone',prop.timezone,'day',day,'updated_at',now(),'can_manage',private.has_permission(p_property,'tasks.assign'),'can_work',private.has_permission(p_property,'tasks.write'));
end $$;
create function public.task_setup(p_property uuid)returns jsonb language plpgsql stable security definer set search_path='' as $$
declare tenant uuid;
begin
 if not private.has_permission(p_property,'tasks.assign')then raise exception 'not permitted'using errcode='42501';end if;
 select tenant_id into tenant from public.properties where id=p_property;
 return jsonb_build_object('assignees',coalesce((select jsonb_agg(jsonb_build_object('id',m.user_id,'name',coalesce(pr.full_name,pr.email,'Teammate'))order by pr.full_name)from public.tenant_memberships m join public.profiles pr on pr.id=m.user_id where m.tenant_id=tenant and private.service_task_eligible(p_property,m.user_id)),'[]'::jsonb),
 'departments',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name)order by name)from public.departments where property_id=p_property),'[]'::jsonb),
 'rooms',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'housekeeping_status',housekeeping_status)order by name)from public.accommodation_units where property_id=p_property and active),'[]'::jsonb));
end $$;
create function public.task_detail(p_property uuid,p_id uuid)returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t record;result jsonb;manager boolean;worker boolean;
begin
 if not private.task_visible(p_id)then raise exception 'not permitted'using errcode='42501';end if;
 select * into t from private.task_rows(p_property)where id=p_id;if not found then raise exception 'Task not found in this hotel.'using errcode='P0002';end if;
 manager:=private.has_permission(p_property,'tasks.assign');worker:=coalesce(t.assignee_id=auth.uid(),false)and private.has_permission(p_property,'tasks.write');
 result:=jsonb_build_object('task',to_jsonb(t),'can_manage',manager,'can_work',manager or worker,'can_claim',t.status='open'and t.assignee_id is null and private.has_permission(p_property,'tasks.write'),
 'can_request',t.guest_request_id is not null and private.service_request_visible(t.guest_request_id),'can_reservation',private.has_permission(p_property,'reservations.read'),
 'checklist',coalesce((select jsonb_agg(jsonb_build_object('id',id,'label',label,'done',done)order by position,id)from public.task_checklists where task_id=t.id),'[]'::jsonb),
 'comments',coalesce((select jsonb_agg(to_jsonb(x)order by x.created_at,x.id)from(select c.id,c.body,c.created_at,coalesce(pr.full_name,pr.email,'Staff')as author_name from public.task_comments c left join public.profiles pr on pr.id=c.author_id where task_id=t.id order by c.created_at desc,c.id desc limit 50)x),'[]'::jsonb),
 'events',coalesce((select jsonb_agg(to_jsonb(x))from(select e.id,e.event_type,e.details,e.created_at,coalesce(pr.full_name,pr.email,'System / staff')as actor_name from public.task_events e left join public.profiles pr on pr.id=e.actor_id where task_id=t.id order by e.created_at desc,e.id desc limit 40)x),'[]'::jsonb));
 if manager then return result||jsonb_build_object('assignees',public.task_setup(p_property)->'assignees');end if;return result||jsonb_build_object('assignees','[]'::jsonb);
end $$;
revoke all on function public.task_workspace(uuid,jsonb),public.task_setup(uuid),public.task_detail(uuid,uuid)from public,anon;
grant execute on function public.task_workspace(uuid,jsonb),public.task_setup(uuid),public.task_detail(uuid,uuid)to authenticated;
