create function private.service_catalog_rows(p_property uuid)
returns table(id uuid,version int,name text,description text,active boolean,default_priority text,target_minutes int,category_id uuid,category text,task_kind text,assignee_id uuid,assignee_name text,department_id uuid,department_name text)
language sql stable security definer set search_path='' as $$
 select c.id,c.version,c.name,c.description,c.active,c.default_priority,coalesce(c.target_minutes,r.sla_minutes),cat.id,cat.name,r.task_kind,r.default_assignee_id,pr.full_name,r.department_id,d.name
 from public.service_catalog c join public.service_categories cat on cat.id=c.category_id left join public.service_routing_rules r on r.catalog_id=c.id
 left join public.profiles pr on pr.id=r.default_assignee_id left join public.departments d on d.id=r.department_id where c.property_id=p_property
$$;
create function private.service_request_rows(p_property uuid)
returns table(id uuid,version int,title text,notes text,status text,priority text,source text,created_at timestamptz,updated_at timestamptz,completed_at timestamptz,due_at timestamptz,overdue boolean,
 guest_name text,reservation_id uuid,stay_status text,room text,requested_room text,service_name text,category text,task_id uuid,task_status text,task_kind text,assignee_id uuid,assignee_name text)
language sql stable security definer set search_path='' as $$
 select g.id,g.version,g.title,g.notes,g.status,g.priority,g.source,g.created_at,g.updated_at,g.completed_at,g.due_at,(g.status in ('new','in_progress') and g.due_at<now()),
 person.full_name,g.reservation_id,r.status,coalesce(current_room.name,requested.name),requested.name,c.name,cat.name,t.id,t.status,t.kind,t.assignee_id,pr.full_name
 from public.guest_requests g join public.reservations r on r.id=g.reservation_id left join public.guests person on person.id=r.guest_id
 left join public.accommodation_units requested on requested.id=g.unit_id
 left join lateral(select u.name from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.reservation_id=r.id order by h.active desc,h.created_at desc limit 1)current_room on true
 left join public.service_catalog c on c.id=g.catalog_id left join public.service_categories cat on cat.id=c.category_id
 left join public.tasks t on t.guest_request_id=g.id left join public.profiles pr on pr.id=t.assignee_id
 where g.property_id=p_property and private.service_request_visible(g.id)
$$;
create function public.service_desk_workspace(p_property uuid,p_filters jsonb default '{}') returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;p public.properties;d date;start_at timestamptz;end_at timestamptz;
 q text:=left(trim(coalesce(p_filters->>'q','')),100);view_filter text:=coalesce(p_filters->>'view','active');pg int:=greatest(1,least(100000,coalesce((p_filters->>'page')::int,1)));
 full_read boolean;
begin
 if not private.has_property_access(p_property) or not(private.has_permission(p_property,'guest_requests.read') or private.has_permission(p_property,'guest_requests.manage') or private.has_permission(p_property,'tasks.read')) then raise exception 'not permitted' using errcode='42501';end if;
 full_read:=private.has_permission(p_property,'guest_requests.read') or private.has_permission(p_property,'guest_requests.manage');
 select * into p from public.properties where id=p_property;d:=(now() at time zone p.timezone)::date;start_at:=d::timestamp at time zone p.timezone;end_at:=(d+1)::timestamp at time zone p.timezone;
 with all_requests as materialized(select * from private.service_request_rows(p_property)),filtered as materialized(
 select * from all_requests g where(q='' or strpos(lower(concat_ws(' ',g.title,g.guest_name,g.room,g.service_name,g.id::text)),lower(q))>0)
 and(coalesce(p_filters->>'priority','')='' or g.priority=p_filters->>'priority')and(coalesce(p_filters->>'source','')='' or g.source=p_filters->>'source')
 and(case view_filter when 'active' then g.status in ('new','in_progress') when 'overdue' then g.overdue when 'mine' then g.assignee_id=auth.uid() and g.status in ('new','in_progress')
 when 'desk' then g.task_id is null and g.status in ('new','in_progress') when 'unassigned' then g.task_id is not null and g.assignee_id is null and g.status in ('new','in_progress')
 when 'completed' then g.status='completed' when 'cancelled' then g.status='cancelled' else true end))
 select jsonb_build_object('total',(select count(*) from filtered),'page',pg,'rows',coalesce((select jsonb_agg(to_jsonb(x)) from(select * from filtered
 order by case when coalesce(p_filters->>'sort','priority')='priority' then case priority when 'urgent' then 0 when 'high' then 1 when 'normal' then 2 else 3 end else 0 end,
 case when coalesce(p_filters->>'sort','priority') in ('priority','deadline') then due_at end asc nulls last,created_at desc,id desc limit 20 offset(pg-1)*20)x),'[]'::jsonb),
 'stats',jsonb_build_object('active',(select count(*) from all_requests where status in ('new','in_progress')),'overdue',(select count(*) from all_requests where overdue),
 'unassigned',(select count(*) from all_requests where task_id is not null and assignee_id is null and status in ('new','in_progress')),
 'desk',(select count(*) from all_requests where task_id is null and status in ('new','in_progress')),
 'completed_today',(select count(*) from all_requests where status='completed' and completed_at>=start_at and completed_at<end_at)))into result;
 return result||jsonb_build_object('timezone',p.timezone,'day',d,'updated_at',now(),'user_id',auth.uid(),'full_read',full_read,
 'can_manage',private.has_permission(p_property,'guest_requests.manage'),'can_catalog',private.has_permission(p_property,'staff.manage'));
end $$;

create function public.service_request_setup(p_property uuid,p_query text default '',p_reservation uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not private.has_permission(p_property,'guest_requests.manage') then raise exception 'not permitted' using errcode='42501';end if;
 with stays as materialized(
 select r.id,person.full_name as guest_name,r.status,r.check_in,r.check_out,
 (select u.name from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.reservation_id=r.id and h.active order by u.name limit 1)as room
 from public.reservations r join public.guests person on person.id=r.guest_id where r.property_id=p_property and r.status in ('confirmed','checked_in')
 and(coalesce(trim(p_query),'')='' or strpos(lower(concat_ws(' ',person.full_name,person.phone,r.id::text)),lower(left(trim(p_query),100)))>0))
 select jsonb_build_object('stay_total',(select count(*) from stays),'stays',coalesce((select jsonb_agg(to_jsonb(x)) from(select * from stays order by case when status='checked_in' then 0 else 1 end,check_in,id limit 20)x),'[]'::jsonb))into result;
 return result||jsonb_build_object('selected',(
 select jsonb_build_object('id',r.id,'guest_name',person.full_name,'status',r.status,'check_in',r.check_in,'check_out',r.check_out,'room',(select u.name from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.reservation_id=r.id and h.active limit 1))
 from public.reservations r join public.guests person on person.id=r.guest_id where r.id=p_reservation and r.property_id=p_property and r.status in ('confirmed','checked_in')),
 'services',coalesce((select jsonb_agg(to_jsonb(c)order by c.category,c.name)from private.service_catalog_rows(p_property)c where c.active),'[]'::jsonb));
end $$;

create function public.service_request_detail(p_property uuid,p_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare g record;t public.tasks;result jsonb;full_read boolean;can_work boolean;
begin
 if not private.service_request_visible(p_id) then raise exception 'not permitted' using errcode='42501';end if;
 select * into g from private.service_request_rows(p_property)where id=p_id;
 if not found then raise exception 'Request not found in this hotel.' using errcode='P0002';end if;
 select * into t from public.tasks where guest_request_id=g.id;
 full_read:=private.has_permission(p_property,'guest_requests.read')or private.has_permission(p_property,'guest_requests.manage');
 can_work:=private.has_permission(p_property,'tasks.assign')or(t.assignee_id=auth.uid()and private.has_permission(p_property,'tasks.write'));
 result:=jsonb_build_object('request',to_jsonb(g),'task',case when t.id is not null then jsonb_build_object('id',t.id,'status',t.status,'kind',t.kind,'priority',t.priority,'due_at',t.due_at,'assignee_id',t.assignee_id,'department',(select name from public.departments where id=t.department_id),'started_at',t.started_at,'completed_at',t.completed_at)end,
 'can_manage',private.has_permission(p_property,'guest_requests.manage'),'can_assign',private.has_permission(p_property,'tasks.assign'),'can_work',coalesce(can_work,false),
 'can_comment',private.has_permission(p_property,'guest_requests.manage')or coalesce(t.assignee_id=auth.uid()and private.has_permission(p_property,'tasks.write'),false),
 'can_claim',t.id is not null and t.status='open'and t.assignee_id is null and private.has_permission(p_property,'tasks.write'),
 'can_reservations',private.has_permission(p_property,'reservations.read'),'feedback',case when full_read then(select jsonb_build_object('rating',rating,'comment',comment,'created_at',created_at,'recorded_via',recorded_via)from public.guest_request_feedback where guest_request_id=g.id)end,
 'assignees',case when private.has_permission(p_property,'tasks.assign')then coalesce((select jsonb_agg(jsonb_build_object('id',m.user_id,'name',coalesce(pr.full_name,pr.email,'Teammate'))order by pr.full_name)from public.tenant_memberships m join public.profiles pr on pr.id=m.user_id where m.tenant_id=(select tenant_id from public.guest_requests where id=g.id)and private.service_task_eligible(p_property,m.user_id)),'[]'::jsonb)else '[]'::jsonb end);
 with history as(
 select e.id,e.event_type,e.details,e.created_at,pr.full_name as actor_name,'request'::text as context from public.guest_request_events e left join public.profiles pr on pr.id=e.actor_id where e.guest_request_id=g.id
 union all select e.id,e.event_type,e.details,e.created_at,pr.full_name,'task'::text from public.task_events e left join public.profiles pr on pr.id=e.actor_id where e.task_id=t.id)
 select result||jsonb_build_object('events',coalesce((select jsonb_agg(to_jsonb(x))from(select * from history order by created_at desc,id desc limit 40)x),'[]'::jsonb))into result;
 with comments as(
 select c.id,c.body,c.created_at,pr.full_name as author_name,'request'::text as context from public.guest_request_comments c left join public.profiles pr on pr.id=c.author_id where c.guest_request_id=g.id
 union all select c.id,c.body,c.created_at,pr.full_name,'task'::text from public.task_comments c left join public.profiles pr on pr.id=c.author_id where c.task_id=t.id)
 select result||jsonb_build_object('comments',coalesce((select jsonb_agg(to_jsonb(x)order by x.created_at,x.id)from(select * from comments order by created_at desc,id desc limit 50)x),'[]'::jsonb))into result;
 return result;
end $$;

create function public.service_catalog_setup(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare tenant uuid;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'not permitted' using errcode='42501';end if;
 select tenant_id into tenant from public.properties where id=p_property;
 return jsonb_build_object('services',coalesce((select jsonb_agg(to_jsonb(c)order by c.category,c.name)from private.service_catalog_rows(p_property)c),'[]'::jsonb),
 'categories',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name)order by name)from public.service_categories where property_id=p_property),'[]'::jsonb),
 'departments',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name)order by name)from public.departments where property_id=p_property),'[]'::jsonb),
 'assignees',coalesce((select jsonb_agg(jsonb_build_object('id',m.user_id,'name',coalesce(pr.full_name,pr.email,'Teammate'))order by pr.full_name)from public.tenant_memberships m join public.profiles pr on pr.id=m.user_id where m.tenant_id=tenant and private.service_task_eligible(p_property,m.user_id)),'[]'::jsonb));
end $$;
revoke all on function private.service_catalog_rows(uuid),private.service_request_rows(uuid)from public,anon,authenticated;
revoke all on function public.service_desk_workspace(uuid,jsonb),public.service_request_setup(uuid,text,uuid),public.service_request_detail(uuid,uuid),public.service_catalog_setup(uuid)from public,anon;
grant execute on function public.service_desk_workspace(uuid,jsonb),public.service_request_setup(uuid,text,uuid),public.service_request_detail(uuid,uuid),public.service_catalog_setup(uuid)to authenticated;

create or replace function public.workspace_permissions(p_property uuid)returns jsonb
language plpgsql stable security invoker set search_path='' as $$
begin
 if not private.has_property_access(p_property)then raise exception 'property not accessible'using errcode='42501';end if;
 return jsonb_build_object('reservations',private.has_permission(p_property,'reservations.read'),'channels',private.has_permission(p_property,'staff.manage'),
 'inbox',private.has_permission(p_property,'whatsapp.use'),'finance',private.has_permission(p_property,'finance.read')or private.has_permission(p_property,'billing.manage'),
 'requests',private.has_permission(p_property,'guest_requests.read')or private.has_permission(p_property,'guest_requests.manage')or private.has_permission(p_property,'tasks.read'),
 'tasks',private.has_permission(p_property,'tasks.read'),'inventory',private.has_permission(p_property,'inventory.manage'),'orders',private.has_permission(p_property,'orders.read'),
 'book',private.has_permission(p_property,'reservations.write'),'frontdesk',private.has_permission(p_property,'frontdesk.manage'));
end $$;
