create table public.whatsapp_template_replacements(
 id uuid primary key default gen_random_uuid(),property_id uuid not null references public.properties(id),old_template uuid not null references public.message_templates(id),
 new_name text not null,language text not null,expected_body text not null,configured_by uuid not null references public.profiles(id),
 state text not null default 'awaiting_approval',last_error text,created_at timestamptz not null default now(),applied_at timestamptz,unique(property_id,new_name,language)
);
alter table public.whatsapp_template_replacements enable row level security;
create policy replacement_read on public.whatsapp_template_replacements for select to authenticated using(private.has_permission(property_id,'staff.manage'));
revoke all on public.whatsapp_template_replacements from public,anon,authenticated;grant select on public.whatsapp_template_replacements to authenticated;grant all on public.whatsapp_template_replacements to service_role;
create function public.register_whatsapp_replacement(p_property uuid,p_actor uuid,p_old uuid,p_name text,p_language text,p_body text)returns void language plpgsql security definer set search_path=''as $$begin
 if not private.whatsapp_actor_allowed(p_property,p_actor)then raise exception 'Hotel administrator access required.'using errcode='42501';end if;
 if not exists(select 1 from public.message_templates t join public.whatsapp_connections c on c.property_id=t.property_id and c.status='active'and c.waba_id=t.provider_waba_id where t.id=p_old and t.property_id=p_property)or p_name!~'^[a-z][a-z0-9_]{2,127}$'or p_name=(select name from public.message_templates where id=p_old)or length(p_body)not between 10 and 1024 then raise exception 'Choose a hotel template and a new version name.'using errcode='22023';end if;
 insert into public.whatsapp_template_replacements(property_id,old_template,new_name,language,expected_body,configured_by)values(p_property,p_old,p_name,p_language,p_body,p_actor)on conflict(property_id,new_name,language)do nothing;
end $$;
create function private.apply_whatsapp_replacements(p_property uuid)returns void language plpgsql security definer set search_path=''as $$
declare item public.whatsapp_template_replacements;t public.message_templates;r public.whatsapp_automation_rules;menu public.whatsapp_guest_menu;data jsonb;k jsonb;s jsonb;cats jsonb;services jsonb;changed boolean;old_claims text;managed boolean;
begin
 for item in select *from public.whatsapp_template_replacements where property_id=p_property and state in('awaiting_approval','needs_attention')order by created_at for update skip locked loop
  if not private.whatsapp_actor_allowed(p_property,item.configured_by)then continue;end if;
  select *into t from public.message_templates where property_id=p_property and name=item.new_name and language=item.language and provider_waba_id=(select waba_id from public.whatsapp_connections where property_id=p_property and status='active');
  if t.id is null or t.provider_status<>'APPROVED'then continue;end if;
  if t.body<>item.expected_body then update public.whatsapp_template_replacements set state='needs_attention',last_error='Provider content differs from the submitted replacement.'where id=item.id;continue;end if;
  old_claims:=current_setting('request.jwt.claims',true);perform set_config('request.jwt.claims',jsonb_build_object('sub',item.configured_by,'role','authenticated')::text,true);
  begin
   for r in select *from public.whatsapp_automation_rules where property_id=p_property and template_id=item.old_template loop
    if not t.automation_supported or t.category<>(case when r.event_key='review_request'then'marketing'else'utility'end)or exists(select 1 from jsonb_array_elements_text(t.parameter_names)x where not private.whatsapp_event_field_allowed(r.event_key,x))then raise exception 'Replacement is incompatible with an assigned event.'using errcode='22023';end if;
    perform public.save_whatsapp_automation_rule(p_property,r.event_key,r.version,r.enabled,t.id,t.parameter_names,r.delay_minutes);
   end loop;
   select *into menu from public.whatsapp_guest_menu where property_id=p_property;
   if menu.data?'categories'then
    cats:='[]';changed:=false;
    for k in select *from jsonb_array_elements(menu.data->'categories')loop
     services:='[]';for s in select *from jsonb_array_elements(k->'services')loop
      if s->>'template_id'=item.old_template::text then s:=s||jsonb_build_object('template_id',t.id);changed:=true;end if;services:=services||jsonb_build_array(s);
     end loop;cats:=cats||jsonb_build_array(k||jsonb_build_object('services',services));
    end loop;
    if changed then
     select menu.version=menu_version into managed from public.whatsapp_default_setup where property_id=p_property;
     perform public.save_whatsapp_guest_menu(p_property,menu.version,menu.enabled,menu.data||jsonb_build_object('categories',cats));
     if managed then update public.whatsapp_default_setup set menu_version=(select version from public.whatsapp_guest_menu where property_id=p_property)where property_id=p_property;end if;
    end if;
   end if;
   update public.whatsapp_default_templates set name=t.name,template_id=t.id,provider_id=t.provider_template_id,state='customized',last_error=null,rule_version=(select version from public.whatsapp_automation_rules where property_id=p_property and event_key=whatsapp_default_templates.event_key)where property_id=p_property and template_id=item.old_template;
   update public.whatsapp_template_replacements set state='applied',last_error=null,applied_at=now()where id=item.id;
  exception when sqlstate '22023'or sqlstate '40001'then update public.whatsapp_template_replacements set state='needs_attention',last_error=left(sqlerrm,400)where id=item.id;
  end;
  perform set_config('request.jwt.claims',coalesce(old_claims,''),true);
 end loop;
 exception when others then perform set_config('request.jwt.claims',coalesce(old_claims,''),true);raise;
end $$;
alter function public.sync_whatsapp_provider_templates(uuid,text,jsonb)rename to sync_whatsapp_provider_templates_before_replacements;
revoke all on function public.sync_whatsapp_provider_templates_before_replacements(uuid,text,jsonb)from public,anon,authenticated,service_role;
create function public.sync_whatsapp_provider_templates(p_connection uuid,p_waba text,p_templates jsonb)returns integer language plpgsql security definer set search_path=''as $$declare n integer;pid uuid;begin
 n:=public.sync_whatsapp_provider_templates_before_replacements(p_connection,p_waba,p_templates);select property_id into pid from public.whatsapp_connections where id=p_connection;perform private.apply_whatsapp_replacements(pid);return n;
end $$;
revoke all on function public.register_whatsapp_replacement(uuid,uuid,uuid,text,text,text),private.apply_whatsapp_replacements(uuid),public.sync_whatsapp_provider_templates(uuid,text,jsonb)from public,anon,authenticated;
revoke all on function private.apply_whatsapp_replacements(uuid)from service_role;
grant execute on function public.register_whatsapp_replacement(uuid,uuid,uuid,text,text,text),public.sync_whatsapp_provider_templates(uuid,text,jsonb)to service_role;

-- The master switch also gates custom automations and queued native replies.
alter function private.whatsapp_automation_error(uuid)rename to whatsapp_automation_error_before_defaults;
revoke all on function private.whatsapp_automation_error_before_defaults(uuid)from public,anon,authenticated,service_role;
create function private.whatsapp_automation_error(p_event uuid)returns text language plpgsql stable security definer set search_path=''as $$begin
 if exists(select 1 from public.whatsapp_automation_events e join public.whatsapp_default_setup s on s.property_id=e.property_id where e.id=p_event and s.configured_by is not null and not s.enabled)then return 'Guest automation is off.';end if;
 if exists(select 1 from public.whatsapp_automation_events e join public.whatsapp_guest_feedback f on f.property_id=e.property_id and f.target_id=e.source_id and f.kind=case when e.event_key='order_feedback'then'food'else'service'end where e.id=p_event and e.event_key in('order_feedback','request_feedback'))then return 'Feedback already received.';end if;return private.whatsapp_automation_error_before_defaults(p_event);
end $$;
alter function private.inbox_delivery_error(uuid)rename to inbox_delivery_error_before_defaults;
revoke all on function private.inbox_delivery_error_before_defaults(uuid)from public,anon,authenticated,service_role;
create function private.inbox_delivery_error(p_message uuid)returns text language plpgsql stable security definer set search_path=''as $$begin
 if exists(select 1 from public.messages m join public.whatsapp_default_setup s on s.property_id=m.property_id where m.id=p_message and s.configured_by is not null and not s.enabled and(m.journey_version is not null or m.guest_menu_automatic))then return 'Guest automation is off.';end if;return private.inbox_delivery_error_before_defaults(p_message);
end $$;
revoke all on function private.whatsapp_automation_error(uuid),private.inbox_delivery_error(uuid)from public,anon,authenticated,service_role;
do $$declare d text;begin
 d:=pg_get_functiondef('private.handle_whatsapp_journey(uuid,uuid,text,text)'::regprocedure);d:=replace(d,'begin'||E'\n select *into c', 'begin'||E'\n if exists(select 1 from public.conversations cv join public.whatsapp_default_setup cfg on cfg.property_id=cv.property_id where cv.id=p_conversation and cfg.configured_by is not null and not cfg.enabled)then return 0;end if;\n select *into c');execute d;
 d:=pg_get_functiondef('private.queue_whatsapp_guest_reply(uuid,uuid,text,boolean,uuid,text)'::regprocedure);d:=replace(d,'begin'||E'\n if p_automatic', 'begin'||E'\n if p_automatic and exists(select 1 from public.conversations cv join public.whatsapp_default_setup cfg on cfg.property_id=cv.property_id where cv.id=p_conversation and cfg.configured_by is not null and not cfg.enabled)then return null;end if;\n if p_automatic');execute d;
 d:=pg_get_functiondef('public.toggle_whatsapp_defaults(uuid,integer,boolean)'::regprocedure);d:=replace(d,' perform private.apply_whatsapp_default_assignments(p_property);',E' if not p_enabled then\n update public.whatsapp_automation_events set state=\'skipped\',reason=\'Guest automation switched off.\'where property_id=p_property and state in(\'pending\',\'blocked\');\n update public.messages set status=\'failed\',error=\'Guest automation switched off.\'where property_id=p_property and status=\'queued\'and(journey_version is not null or guest_menu_automatic or automation_event_id is not null);\n end if;\n perform private.apply_whatsapp_default_assignments(p_property);');execute d;
end $$;

do $$declare d text;begin
 d:=pg_get_functiondef('private.capture_whatsapp_event(uuid,uuid,text,text,text,uuid,text,jsonb,timestamp with time zone,timestamp with time zone)'::regprocedure);
 d:=replace(d,'begin'||E'\n if p_event=', 'begin'||E'\n if exists(select 1 from public.whatsapp_default_setup cfg where cfg.property_id=p_property and cfg.configured_by is not null and not cfg.enabled)then return;end if;\n if p_event=');execute d;
end $$;

do $$declare d text;begin d:=pg_get_functiondef('public.dispatch_whatsapp_automations(integer,text)'::regprocedure);d:=replace(d,'''Source status changed.'')','''Source status changed.'',''Feedback already received.'')');execute d;end $$;
