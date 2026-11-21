-- Historical assignments remain, but reopening work cannot strand it on a teammate who lost access.
create or replace function private.staff_assignment_guard()returns trigger language plpgsql security definer set search_path=''as $$
declare target uuid;
begin
 if not exists(select 1 from public.tenants where id=new.tenant_id)then return new;end if;
 perform pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended('staff-tenant:'||new.tenant_id::text,0));
 if tg_table_name='tasks'then
 target:=new.assignee_id;
 if target is not null and new.status in('open','in_progress')and auth.uid()is not null and exists(select 1 from public.property_memberships where property_id=new.property_id and user_id=target)and not private.service_task_eligible(new.property_id,target)then
 if tg_op='UPDATE'then if old.status in('done','cancelled')then
 new.assignee_id:=null;insert into public.task_events(tenant_id,property_id,task_id,event_type,actor_id,details)values(new.tenant_id,new.property_id,new.id,'assigned',auth.uid(),jsonb_build_object('assignee',null,'reason','Previous assignee no longer has task-work access.'));return new;
 end if;end if;raise exception 'Choose a teammate with task-work access to this hotel.'using errcode='22023';end if;
 elsif tg_table_name='conversations'then
 target:=new.assigned_to;
 if target is not null and new.status='open'and auth.uid()is not null and exists(select 1 from public.property_memberships where property_id=new.property_id and user_id=target)and not private.inbox_eligible_user(new.property_id,target)then
 if tg_op='UPDATE'then if old.status='closed'then new.assigned_to:=null;return new;end if;end if;raise exception 'Choose a teammate with inbox access to this hotel.'using errcode='22023';end if;
 else target:=new.default_assignee_id;
 if target is not null and auth.uid()is not null and not private.service_task_eligible(new.property_id,target)then raise exception 'Choose a default assignee with task-work access.'using errcode='22023';end if;
 end if;return new;
end $$;
drop trigger staff_assignment_guard on public.tasks;
drop trigger staff_assignment_guard on public.conversations;
create trigger staff_assignment_guard before insert or update of assignee_id,status on public.tasks for each row execute function private.staff_assignment_guard();
create trigger staff_assignment_guard before insert or update of assigned_to,status on public.conversations for each row execute function private.staff_assignment_guard();
