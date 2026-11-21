-- Assignment writers share the business-access lock, so revocation cannot race a new claim.
create function private.staff_assignment_guard()returns trigger language plpgsql security definer set search_path=''as $$
declare target uuid;
begin
 if not exists(select 1 from public.tenants where id=new.tenant_id)then return new;end if;
 perform pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended('staff-tenant:'||new.tenant_id::text,0));
 if tg_table_name='tasks'then
 target:=new.assignee_id;
 if target is not null and new.status in('open','in_progress')and auth.uid()is not null and exists(select 1 from public.property_memberships where property_id=new.property_id and user_id=target)and not private.service_task_eligible(new.property_id,target)then raise exception 'Choose a teammate with task-work access to this hotel.'using errcode='22023';end if;
 else target:=new.assigned_to;
 if target is not null and new.status='open'and auth.uid()is not null and exists(select 1 from public.property_memberships where property_id=new.property_id and user_id=target)and not private.inbox_eligible_user(new.property_id,target)then raise exception 'Choose a teammate with inbox access to this hotel.'using errcode='22023';end if;
 end if;return new;
end $$;
revoke all on function private.staff_assignment_guard()from public,anon,authenticated;
create trigger staff_assignment_guard before insert or update of assignee_id on public.tasks for each row execute function private.staff_assignment_guard();
create trigger staff_assignment_guard before insert or update of assigned_to on public.conversations for each row execute function private.staff_assignment_guard();
create or replace function private.lock_task(p_id uuid)returns public.tasks language plpgsql security definer set search_path=''as $$
declare t public.tasks;linked uuid;room uuid;work_kind text;tenant uuid;
begin
 select tenant_id,guest_request_id,unit_id,kind into tenant,linked,room,work_kind from public.tasks where id=p_id;
 if tenant is not null then perform pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended('staff-tenant:'||tenant::text,0));end if;
 if linked is not null then perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('service-request:'||linked::text,0));end if;
 if room is not null and work_kind='housekeeping'then perform 1 from public.accommodation_units where id=room for update;end if;
 select * into t from public.tasks where id=p_id for update;if not found then raise exception 'not permitted'using errcode='42501';end if;return t;
end $$;
create or replace function private.lock_conversation(p_id uuid,p_perm text)returns public.conversations language plpgsql security definer set search_path=''as $$
declare c public.conversations;tenant uuid;
begin
 select tenant_id into tenant from public.conversations where id=p_id;
 if tenant is not null then perform pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended('staff-tenant:'||tenant::text,0));end if;
 select * into c from public.conversations where id=p_id for update;if not found or not private.has_permission(c.property_id,p_perm)then raise exception 'not permitted'using errcode='42501';end if;return c;
end $$;
