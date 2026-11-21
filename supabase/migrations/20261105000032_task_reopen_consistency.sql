-- A reopened cleaning task must be checked again; cancelled cleaning leaves a dirty room.
create or replace function public.set_task_status(p_id uuid,p_status text)returns void language plpgsql security definer set search_path='' as $$
declare t public.tasks;manager boolean;worker boolean;
begin
 t:=private.lock_task(p_id);manager:=private.has_permission(t.property_id,'tasks.assign');worker:=coalesce(t.assignee_id=auth.uid(),false)and private.has_permission(t.property_id,'tasks.write');
 if not(manager or worker)then raise exception 'not permitted'using errcode='42501';end if;
 if(t.status,p_status)not in(('open','in_progress'),('open','done'),('in_progress','done'),('in_progress','open'),('open','cancelled'),('in_progress','cancelled'),('done','open'),('cancelled','open'))then raise exception 'invalid transition % -> %',t.status,p_status using errcode='22023';end if;
 if(p_status='cancelled'or t.status in('done','cancelled'))and not manager then raise exception 'not permitted'using errcode='42501';end if;
 update public.tasks set status=p_status,started_at=case when p_status='open'and t.status in('done','cancelled')then null when p_status='in_progress'then coalesce(started_at,now())else started_at end,
 completed_at=case when p_status='done'then now()end where id=p_id;
 if p_status='open'and t.status in('done','cancelled')then update public.task_checklists set done=false where task_id=t.id;end if;
 if t.kind='housekeeping'and t.unit_id is not null then update public.accommodation_units set housekeeping_status=case p_status when 'in_progress'then 'in_progress'when 'done'then 'clean'when 'open'then 'dirty'when 'cancelled'then 'dirty'else housekeeping_status end where id=t.unit_id;end if;
 insert into public.task_events(tenant_id,property_id,task_id,event_type,actor_id,details)values(t.tenant_id,t.property_id,p_id,'status_changed',auth.uid(),jsonb_build_object('from',t.status,'to',p_status));
end $$;
