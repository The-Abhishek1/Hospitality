-- Provider templates are retired locally, never erased from message history.
alter table public.message_templates add column deleted_at timestamptz,add column deleted_provider_template_id text;
create table private.whatsapp_template_deletions(
 id uuid primary key default gen_random_uuid(),property_id uuid not null references public.properties(id),template_id uuid not null references public.message_templates(id),
 connection_id uuid not null references public.whatsapp_connections(id),waba_id text not null,provider_id text not null,name text not null,language text not null,actor_id uuid not null,
 state text not null default 'pending'check(state in('pending','uncertain','deleted','failed')),created_at timestamptz not null default clock_timestamp(),finished_at timestamptz
);
create unique index template_deletion_active on private.whatsapp_template_deletions(template_id)where state in('pending','uncertain');
revoke all on private.whatsapp_template_deletions from public,anon,authenticated,service_role;

create function public.whatsapp_template_deletion_context(p_property uuid,p_template uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare t public.message_templates;c public.whatsapp_connections;blockers jsonb:='[]';events jsonb;services integer;campaigns integer;queued integer;shared integer;deleting boolean;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel administrator access required.'using errcode='42501';end if;
 if not exists(select 1 from public.properties where id=p_property and archived_at is null and private.tenant_is_active(tenant_id))then raise exception 'Hotel is closed or inactive.'using errcode='42501';end if;
 select *into t from public.message_templates where property_id=p_property and id=p_template;
 if t.id is null then raise exception 'Template not found for this hotel.'using errcode='P0002';end if;
 select *into c from public.whatsapp_connections where property_id=p_property;
 select coalesce(jsonb_agg(event_key order by event_key),'[]')into events from public.whatsapp_automation_rules where property_id=p_property and template_id=t.id and enabled;
 select count(*)into services from public.whatsapp_guest_menu m cross join lateral jsonb_array_elements(coalesce(m.data->'categories','[]'))cat cross join lateral jsonb_array_elements(coalesce(cat->'services','[]'))s where m.property_id=p_property and m.enabled and cat->>'enabled'='true'and s->>'enabled'='true'and s->>'template_id'=t.id::text;
 select count(*)into campaigns from public.whatsapp_campaigns where property_id=p_property and template_id=t.id and status in('scheduled','running');
 select count(*)into queued from public.messages where property_id=p_property and template_id=t.id and direction='out'and(status in('queued','sending')or delivery_uncertain);
 select count(*)into shared from public.whatsapp_connections where property_id<>p_property and waba_id=t.provider_waba_id and status='active';
 deleting:=exists(select 1 from private.whatsapp_template_deletions where template_id=t.id and state in('pending','uncertain'));
 if c.status is distinct from 'active'or c.waba_id is distinct from t.provider_waba_id then blockers:=blockers||jsonb_build_array('Reconnect the WhatsApp account that owns this template.');end if;
 if t.provider_template_id is null then blockers:=blockers||jsonb_build_array('Only templates synced from Meta can be deleted here.');end if;
 if t.name in('hello_world','jaspers_market_image_cta_v1','jaspers_market_media_carousel_v1','jaspers_market_order_confirmation_v1','jaspers_market_plain_text_v1')then blockers:=blockers||jsonb_build_array('Meta sample templates cannot be deleted here.');end if;
 if t.provider_status='DISABLED'then blockers:=blockers||jsonb_build_array('Meta does not allow deletion of disabled templates.');end if;
 if t.provider_status in('MISSING','PENDING_DELETION')and t.deleted_at is null then blockers:=blockers||jsonb_build_array('Sync this template’s current Meta status before deleting it.');end if;
 if jsonb_array_length(events)>0 then blockers:=blockers||jsonb_build_array('Pause or replace the active event rules using this template first.');end if;
 if services>0 then blockers:=blockers||jsonb_build_array('Replace this template in the published guest menu, or unpublish the menu first.');end if;
 if campaigns>0 then blockers:=blockers||jsonb_build_array('Cancel the scheduled or running campaigns using this template first.');end if;
 if queued>0 then blockers:=blockers||jsonb_build_array('Messages are queued, sending, or have an unknown delivery result. Resolve these deliveries first.');end if;
 if shared>0 then blockers:=blockers||jsonb_build_array('Another hotel is connected to this Meta account. This template is shared; manage deletion in Meta after reviewing those hotels.');end if;
 if deleting then blockers:=blockers||jsonb_build_array('Deletion is in progress or awaiting confirmation. Check approval & sync before trying again.');end if;
 return jsonb_build_object('id',t.id,'name',t.name,'language',t.language,'status',t.provider_status,'provider_id',t.provider_template_id,'deleted',t.deleted_at is not null,'can_delete',t.deleted_at is null and jsonb_array_length(blockers)=0,'blockers',blockers,'usage',jsonb_build_object('events',events,'services',services,'campaigns',campaigns,'messages',queued,'shared_hotels',shared));
end $$;
create function public.begin_whatsapp_template_deletion(p_property uuid,p_template uuid,p_provider_id text,p_confirm_name text,p_confirm_language text)returns jsonb
language plpgsql security definer set search_path=''as $$
declare context jsonb;t public.message_templates;c public.whatsapp_connections;op uuid;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel administrator access required.'using errcode='42501';end if;
 -- Match rule configuration's property-first lock order, while allowing FK readers.
 perform 1 from public.properties where id=p_property for no key update;
 perform pg_advisory_xact_lock(hashtextextended('wa-template-delete:'||p_template::text,0));
 select *into t from public.message_templates where id=p_template and property_id=p_property for update;
 if t.id is null then raise exception 'Template not found for this hotel.'using errcode='P0002';end if;
 if t.name is distinct from p_confirm_name or t.language is distinct from p_confirm_language or t.provider_template_id is distinct from p_provider_id then raise exception 'Template changed. Review its name and language again.'using errcode='40001';end if;
 context:=public.whatsapp_template_deletion_context(p_property,p_template);
 if t.deleted_at is not null then return jsonb_build_object('already_deleted',true);end if;
 if not(context->>'can_delete')::boolean then raise exception '%',context->'blockers'->>0 using errcode='22023';end if;
 select *into c from public.whatsapp_connections where property_id=p_property;
 insert into private.whatsapp_template_deletions(property_id,template_id,connection_id,waba_id,provider_id,name,language,actor_id)values(p_property,t.id,c.id,c.waba_id,t.provider_template_id,t.name,t.language,auth.uid())returning id into op;
 insert into public.whatsapp_automation_audit(property_id,tenant_id,actor,action,details)values(p_property,t.tenant_id,auth.uid(),'template_delete_requested',jsonb_build_object('template',t.id,'name',t.name,'language',t.language,'operation',op));
 return jsonb_build_object('operation',op,'waba_id',c.waba_id,'provider_id',t.provider_template_id,'name',t.name,'language',t.language);
end $$;
create function public.finish_whatsapp_template_deletion(p_operation uuid,p_outcome text)returns boolean
language plpgsql security definer set search_path=''as $$
declare op private.whatsapp_template_deletions;t public.message_templates;
begin
 if p_outcome is null or p_outcome not in('deleted','failed','uncertain')then raise exception 'Invalid deletion outcome.'using errcode='22023';end if;
 select *into op from private.whatsapp_template_deletions where id=p_operation;
 if op.id is null then raise exception 'Deletion operation unavailable.'using errcode='P0002';end if;
 -- Match sync's row-lock order; the pending marker protects new uses until this commits.
 select *into t from public.message_templates where id=op.template_id for update;
 select *into op from private.whatsapp_template_deletions where id=p_operation for update;
 if op.state in('deleted','failed')then return op.state='deleted';end if;
 if p_outcome='deleted'and t.provider_template_id=op.provider_id and t.provider_waba_id=op.waba_id then
  update public.message_templates set deleted_at=clock_timestamp(),deleted_provider_template_id=op.provider_id,status='rejected',provider_status='DELETED',automation_supported=false,service_supported=false,campaign_supported=false where id=t.id;
 end if;
 update private.whatsapp_template_deletions set state=p_outcome,finished_at=case when p_outcome='uncertain'then null else clock_timestamp()end where id=op.id;
 insert into public.whatsapp_automation_audit(property_id,tenant_id,actor,action,details)values(op.property_id,t.tenant_id,op.actor_id,'template_delete_'||p_outcome,jsonb_build_object('template',t.id,'name',op.name,'language',op.language,'operation',op.id));return p_outcome='deleted';
end $$;
revoke all on function public.whatsapp_template_deletion_context(uuid,uuid),public.begin_whatsapp_template_deletion(uuid,uuid,text,text,text)from public,anon;
grant execute on function public.whatsapp_template_deletion_context(uuid,uuid),public.begin_whatsapp_template_deletion(uuid,uuid,text,text,text)to authenticated;
revoke all on function public.finish_whatsapp_template_deletion(uuid,text)from public,anon,authenticated;
grant execute on function public.finish_whatsapp_template_deletion(uuid,text)to service_role;

-- Serialize new uses with deletion, so a template cannot become active after the usage check.
create function private.guard_live_template(p_template uuid)returns void language plpgsql security definer set search_path=''as $$
begin
 if p_template is null then return;end if;
 perform pg_advisory_xact_lock(hashtextextended('wa-template-delete:'||p_template::text,0));
 if exists(select 1 from public.message_templates t where t.id=p_template and(t.deleted_at is not null or exists(select 1 from private.whatsapp_template_deletions op where op.template_id=t.id and op.state in('pending','uncertain'))))then raise exception 'This template is deleted or deletion is awaiting confirmation. Sync and choose another template.'using errcode='22023';end if;
end $$;
create function private.guard_deleted_template_use()returns trigger language plpgsql security definer set search_path=''as $$
declare tid uuid;
begin
 if tg_table_name='whatsapp_guest_menu'then
  if new.enabled then
   for tid in select distinct(s->>'template_id')::uuid from jsonb_array_elements(coalesce(new.data->'categories','[]'))cat cross join lateral jsonb_array_elements(coalesce(cat->'services','[]'))s where cat->>'enabled'='true'and s->>'enabled'='true'and nullif(s->>'template_id','')is not null order by 1 loop perform private.guard_live_template(tid);end loop;
  end if;
 elsif tg_table_name='whatsapp_automation_rules'then if new.enabled then perform private.guard_live_template(new.template_id);end if;
 elsif tg_table_name='whatsapp_campaigns'then if new.status in('scheduled','running')then perform private.guard_live_template(new.template_id);end if;
 elsif tg_table_name='messages'then if new.direction='out'and new.status in('queued','sending')then perform private.guard_live_template(new.template_id);end if;
 end if;
 return new;
end $$;
revoke all on function private.guard_live_template(uuid),private.guard_deleted_template_use()from public,anon,authenticated,service_role;
create trigger protect_template_deletion before insert or update on public.whatsapp_automation_rules for each row execute function private.guard_deleted_template_use();
create trigger protect_template_deletion before insert or update on public.whatsapp_guest_menu for each row execute function private.guard_deleted_template_use();
create trigger protect_template_deletion before insert or update on public.whatsapp_campaigns for each row execute function private.guard_deleted_template_use();
create trigger protect_template_deletion before insert or update on public.messages for each row execute function private.guard_deleted_template_use();

-- Full provider sync reconciles interrupted DELETE calls; deleted records retain history.
alter function public.sync_whatsapp_provider_templates(uuid,text,jsonb)rename to sync_whatsapp_provider_templates_before_deletion;
revoke all on function public.sync_whatsapp_provider_templates_before_deletion(uuid,text,jsonb)from public,anon,authenticated,service_role;
create function public.sync_whatsapp_provider_templates(p_connection uuid,p_waba text,p_templates jsonb)returns integer language plpgsql security definer set search_path=''as $$
declare n integer;op private.whatsapp_template_deletions;provider jsonb;pid uuid;
begin
 n:=public.sync_whatsapp_provider_templates_before_deletion(p_connection,p_waba,p_templates);
 select property_id into pid from public.whatsapp_connections where id=p_connection;
 for op in select *from private.whatsapp_template_deletions where property_id=pid and waba_id=p_waba and(state='uncertain'or state='pending'and created_at<clock_timestamp()-interval '2 minutes')loop
  select x into provider from jsonb_array_elements(p_templates)x where x->>'provider_id'=op.provider_id;
  perform public.finish_whatsapp_template_deletion(op.id,case when provider is null or provider->>'provider_status'in('PENDING_DELETION','DELETED')then'deleted'else'failed'end);
 end loop;
 update public.message_templates set deleted_at=null,deleted_provider_template_id=null where property_id=pid and deleted_at is not null and provider_template_id is distinct from deleted_provider_template_id;
 update public.message_templates set status='rejected',provider_status=case when provider_status='PENDING_DELETION'then provider_status else'DELETED'end,automation_supported=false,service_supported=false,campaign_supported=false where property_id=pid and deleted_at is not null;
 return n;
end $$;
revoke all on function public.sync_whatsapp_provider_templates(uuid,text,jsonb)from public,anon,authenticated;
grant execute on function public.sync_whatsapp_provider_templates(uuid,text,jsonb)to service_role;

alter function public.whatsapp_automation_workspace(uuid,integer)rename to whatsapp_automation_workspace_before_deletion;
revoke all on function public.whatsapp_automation_workspace_before_deletion(uuid,integer)from public,anon,authenticated,service_role;
create function public.whatsapp_automation_workspace(p_property uuid,p_page integer default 1)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare d jsonb;
begin
 d:=public.whatsapp_automation_workspace_before_deletion(p_property,p_page);
 return d||jsonb_build_object('templates',coalesce((select jsonb_agg(x)from jsonb_array_elements(d->'templates')x join public.message_templates t on t.id=(x->>'id')::uuid where t.deleted_at is null and t.provider_status is distinct from 'MISSING'),'[]'));
end $$;
revoke all on function public.whatsapp_automation_workspace(uuid,integer)from public,anon;
grant execute on function public.whatsapp_automation_workspace(uuid,integer)to authenticated;
alter function public.whatsapp_service_templates(uuid)rename to whatsapp_service_templates_before_deletion;
revoke all on function public.whatsapp_service_templates_before_deletion(uuid)from public,anon,authenticated,service_role;
create function public.whatsapp_service_templates(p_property uuid)returns jsonb language sql stable security definer set search_path=''as $$
 select coalesce(jsonb_agg(x),'[]')from jsonb_array_elements(public.whatsapp_service_templates_before_deletion(p_property))x join public.message_templates t on t.id=(x->>'id')::uuid where t.deleted_at is null and t.provider_status is distinct from 'MISSING';
$$;
revoke all on function public.whatsapp_service_templates(uuid)from public,anon;
grant execute on function public.whatsapp_service_templates(uuid)to authenticated;
