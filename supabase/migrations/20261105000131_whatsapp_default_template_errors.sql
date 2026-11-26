-- Retain actionable per-template failures while allowing unrelated slots to progress.
create function public.record_whatsapp_default_failure(p_property uuid,p_lease uuid,p_slot text,p_error text)returns void
language plpgsql security definer set search_path=''as $$begin
 if not exists(select 1 from public.whatsapp_default_setup where property_id=p_property and lease=p_lease for update)then raise exception 'Setup lease changed.'using errcode='40001';end if;
 if length(trim(coalesce(p_error,'')))not between 5 and 500 then raise exception 'Provide a safe template setup error.'using errcode='22023';end if;
 update public.whatsapp_default_templates set last_error=left(p_error,400)where property_id=p_property and slot=p_slot and state<>'customized';
 if not found then raise exception 'Unknown or customized default template.'using errcode='22023';end if;
end $$;
revoke all on function public.record_whatsapp_default_failure(uuid,uuid,text,text)from public,anon,authenticated;
grant execute on function public.record_whatsapp_default_failure(uuid,uuid,text,text)to service_role;

-- Track future handoff changes. Historical flags intentionally keep an unknown actor/time.
alter table public.conversations add column handoff_changed_at timestamptz,
 add column handoff_actor_id uuid references public.profiles(id)on delete set null,
 add column handoff_actor_name text,add column handoff_origin text check(handoff_origin in('staff','automation'));
create function private.track_conversation_handoff()returns trigger language plpgsql security definer set search_path=''as $$
begin
 if new.human_handoff is distinct from old.human_handoff then
  new.handoff_changed_at:=clock_timestamp();
  new.handoff_actor_id:=null;new.handoff_actor_name:=null;new.handoff_origin:='automation';
  if auth.role()='authenticated'and auth.uid()is not null then
   select id,coalesce(nullif(full_name,''),email,'Staff member')into new.handoff_actor_id,new.handoff_actor_name from public.profiles where id=auth.uid();
   if new.handoff_actor_id is not null then new.handoff_origin:='staff';end if;
  end if;
 end if;
 return new;
end $$;
revoke all on function private.track_conversation_handoff()from public,anon,authenticated,service_role;
create trigger track_conversation_handoff before update of human_handoff on public.conversations for each row execute function private.track_conversation_handoff();
