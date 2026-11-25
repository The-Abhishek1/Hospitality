create table public.whatsapp_default_setup(
 property_id uuid primary key references public.properties(id),connection_id uuid references public.whatsapp_connections(id),configured_by uuid references public.profiles(id),
 enabled boolean not null default false,version integer not null default 1,state text not null default 'needs_information',photo_ids jsonb not null default '[]',welcome_image_url text,
 next_check_at timestamptz not null default now(),lease uuid,locked_at timestamptz,last_error text,menu_version integer,journey_managed boolean not null default false,updated_at timestamptz not null default now()
);
create table public.whatsapp_default_templates(
 property_id uuid not null references public.properties(id),slot text not null,name text not null,kind text not null check(kind in('event','menu')),event_key text,
 template_id uuid references public.message_templates(id),provider_id text,state text not null default 'queued',rule_version integer,last_error text,
 primary key(property_id,slot),unique(property_id,name)
);
alter table public.whatsapp_default_setup enable row level security;alter table public.whatsapp_default_templates enable row level security;
create policy default_setup_read on public.whatsapp_default_setup for select to authenticated using(private.has_permission(property_id,'staff.manage'));
create policy default_templates_read on public.whatsapp_default_templates for select to authenticated using(private.has_permission(property_id,'staff.manage'));
revoke all on public.whatsapp_default_setup,public.whatsapp_default_templates from public,anon,authenticated;grant select on public.whatsapp_default_setup,public.whatsapp_default_templates to authenticated;grant all on public.whatsapp_default_setup,public.whatsapp_default_templates to service_role;
create function private.whatsapp_default_slots()returns jsonb language sql immutable set search_path=''as $$select '[{"key": "booking_confirmed", "event": "booking_confirmed", "kind": "event", "delay": 0, "activate": true}, {"key": "booking_changed", "event": "booking_changed", "kind": "event", "delay": 0, "activate": true}, {"key": "booking_cancelled", "event": "booking_cancelled", "kind": "event", "delay": 0, "activate": true}, {"key": "checked_in", "event": "checked_in", "kind": "event", "delay": 0, "activate": true}, {"key": "checked_out", "event": "checked_out", "kind": "event", "delay": 0, "activate": true}, {"key": "arrival_reminder", "event": "arrival_reminder", "kind": "event", "delay": 180, "activate": true}, {"key": "checkout_reminder", "event": "checkout_reminder", "kind": "event", "delay": 120, "activate": true}, {"key": "review_request", "event": "review_request", "kind": "event", "delay": 0, "activate": false}, {"key": "order_placed", "event": "order_placed", "kind": "event", "delay": 0, "activate": true}, {"key": "order_preparing", "event": "order_preparing", "kind": "event", "delay": 0, "activate": true}, {"key": "order_ready", "event": "order_ready", "kind": "event", "delay": 0, "activate": true}, {"key": "order_served", "event": "order_served", "kind": "event", "delay": 0, "activate": true}, {"key": "order_cancelled", "event": "order_cancelled", "kind": "event", "delay": 0, "activate": true}, {"key": "request_received", "event": "request_received", "kind": "event", "delay": 0, "activate": true}, {"key": "request_started", "event": "request_started", "kind": "event", "delay": 0, "activate": true}, {"key": "request_completed", "event": "request_completed", "kind": "event", "delay": 0, "activate": true}, {"key": "request_cancelled", "event": "request_cancelled", "kind": "event", "delay": 0, "activate": true}, {"key": "payment_received", "event": "payment_received", "kind": "event", "delay": 0, "activate": true}, {"key": "payment_refunded", "event": "payment_refunded", "kind": "event", "delay": 0, "activate": true}, {"key": "invoice_issued", "event": "invoice_issued", "kind": "event", "delay": 0, "activate": true}, {"key": "documents_received", "event": "documents_received", "kind": "event", "delay": 0, "activate": true}, {"key": "documents_approved", "event": "documents_approved", "kind": "event", "delay": 0, "activate": true}, {"key": "documents_rejected", "event": "documents_rejected", "kind": "event", "delay": 0, "activate": true}, {"key": "order_feedback", "event": "order_feedback", "kind": "event", "delay": 20, "activate": true}, {"key": "request_feedback", "event": "request_feedback", "kind": "event", "delay": 5, "activate": true}, {"key": "menu_stay", "kind": "menu", "label": "My stay", "group": "My stay", "action": "reply", "native_action": "stay", "activate": true}, {"key": "menu_documents", "kind": "menu", "label": "Upload documents", "group": "My stay", "action": "reply", "native_action": "documents", "activate": true}, {"key": "menu_checkin", "kind": "menu", "label": "Check in", "group": "My stay", "action": "reply", "native_action": "checkin", "activate": true}, {"key": "menu_checkout", "kind": "menu", "label": "Check out", "group": "My stay", "action": "reply", "native_action": "checkout", "activate": true}, {"key": "menu_bill", "kind": "menu", "label": "My bill", "group": "My stay", "action": "reply", "native_action": "bill", "activate": true}, {"key": "menu_food", "kind": "menu", "label": "Order food", "group": "Food & services", "action": "reply", "native_action": "food", "activate": true}, {"key": "menu_services", "kind": "menu", "label": "Request a service", "group": "Food & services", "action": "reply", "native_action": "services", "activate": true}, {"key": "menu_location", "kind": "menu", "label": "Hotel location", "group": "Hotel information", "action": "reply", "native_action": "location", "activate": true}, {"key": "menu_photos", "kind": "menu", "label": "Hotel photos", "group": "Hotel information", "action": "reply", "native_action": "photos", "activate": true}, {"key": "menu_website", "kind": "menu", "label": "Hotel website", "group": "Hotel information", "action": "reply", "native_action": "website", "activate": true}, {"key": "menu_review", "kind": "menu", "label": "Leave a review", "group": "Hotel information", "action": "reply", "native_action": "review", "activate": true}, {"key": "menu_reception", "kind": "menu", "label": "Talk to reception", "group": "Reception", "action": "reception", "native_action": "reception", "activate": true}]'::jsonb$$;

create function private.seed_whatsapp_defaults(p_property uuid,p_connection uuid)returns void language plpgsql security definer set search_path=''as $$declare slot jsonb;begin
 insert into public.whatsapp_default_setup(property_id,connection_id)values(p_property,p_connection)on conflict(property_id)do update set connection_id=excluded.connection_id,next_check_at=now(),state='needs_information',lease=null,locked_at=null,version=whatsapp_default_setup.version+1;
 for slot in select *from jsonb_array_elements(private.whatsapp_default_slots())loop
  insert into public.whatsapp_default_templates(property_id,slot,name,kind,event_key)values(p_property,slot->>'key','hp_'||replace(p_property::text,'-','')||'_'||(slot->>'key')||'_v1',slot->>'kind',slot->>'event')on conflict do nothing;
 end loop;
end $$;
create function private.initialize_whatsapp_defaults()returns trigger language plpgsql security definer set search_path=''as $$begin
 if new.status='active'and(tg_op='INSERT'or old.status is distinct from new.status or old.waba_id is distinct from new.waba_id)then perform private.seed_whatsapp_defaults(new.property_id,new.id);end if;return new;
end $$;
create trigger initialize_whatsapp_defaults after insert or update of status,waba_id on public.whatsapp_connections for each row execute function private.initialize_whatsapp_defaults();

create function public.whatsapp_default_workspace(p_property uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel administrator access required.'using errcode='42501';end if;
 return jsonb_build_object('setup',(select to_jsonb(s)-'lease'-'locked_at'from public.whatsapp_default_setup s where property_id=p_property),'slots',coalesce((select jsonb_agg(to_jsonb(t)||jsonb_build_object('label',coalesce(c->>'label',(select e->>'label'from jsonb_array_elements(public.whatsapp_automation_catalog())e where e->>'key'=t.event_key),t.slot)))from public.whatsapp_default_templates t join lateral(select value as c from jsonb_array_elements(private.whatsapp_default_slots())where value->>'key'=t.slot)x on true where t.property_id=p_property),'[]'));
end $$;
create function public.save_whatsapp_default_setup(p_property uuid,p_actor uuid,p_version integer,p_photos jsonb,p_image text)returns void language plpgsql security definer set search_path=''as $$declare c public.whatsapp_connections;s public.whatsapp_default_setup;links jsonb;begin
 if not private.whatsapp_actor_allowed(p_property,p_actor)then raise exception 'Hotel administrator access required.'using errcode='42501';end if;
 select *into c from public.whatsapp_connections where property_id=p_property and status='active';if c.id is null then raise exception 'Connect this hotel’s WhatsApp account first.'using errcode='22023';end if;
 if not exists(select 1 from public.whatsapp_default_setup where property_id=p_property)then perform private.seed_whatsapp_defaults(p_property,c.id);end if;
 select *into s from public.whatsapp_default_setup where property_id=p_property for update;
 if s.version is distinct from p_version and not(p_version=0 and s.configured_by is null)then raise exception 'Setup changed. Refresh before saving.'using errcode='40001';end if;
 select data into links from public.whatsapp_guest_settings where property_id=p_property;
 if not coalesce(private.whatsapp_public_link(links->>'maps_url'),false)or not coalesce(private.whatsapp_public_link(links->>'review_url'),false)then raise exception 'Save this hotel’s HTTPS location and review links first.'using errcode='22023';end if;
 if jsonb_typeof(p_photos)is distinct from'array'or jsonb_array_length(p_photos)not between 3 and 4 or(select count(distinct value)from jsonb_array_elements_text(p_photos))<>jsonb_array_length(p_photos)or exists(select 1 from jsonb_array_elements_text(p_photos)x where not exists(select 1 from public.hotel_message_photos p where p.id::text=x and p.property_id=p_property and not archived))or not exists(select 1 from public.hotel_message_photos where property_id=p_property and url=p_image and not archived)then raise exception 'Choose three or four saved hotel photos and a generated welcome collage.'using errcode='22023';end if;
 update public.whatsapp_default_setup set configured_by=p_actor,connection_id=c.id,photo_ids=p_photos,welcome_image_url=p_image,state='queued',last_error=null,next_check_at=now(),version=version+1,updated_at=now()where property_id=p_property;
end $$;

create function private.apply_whatsapp_default_assignments(p_property uuid)returns void language plpgsql security definer set search_path=''as $$
declare cfg public.whatsapp_default_setup;slot record;t public.message_templates;r public.whatsapp_automation_rules;keys jsonb;old_claims text;metadata jsonb;categories jsonb:='[]';services jsonb;cat text;menu public.whatsapp_guest_menu;journey public.whatsapp_journey_settings;all_ready boolean:=true;menu_ready boolean:=true;native text;desired boolean;
begin
 select *into cfg from public.whatsapp_default_setup where property_id=p_property for update;
 if cfg.configured_by is null or not private.whatsapp_actor_allowed(p_property,cfg.configured_by)or cfg.connection_id is distinct from(select id from public.whatsapp_connections where property_id=p_property and status='active')then return;end if;
 old_claims:=current_setting('request.jwt.claims',true);perform set_config('request.jwt.claims',jsonb_build_object('sub',cfg.configured_by,'role','authenticated')::text,true);
 for slot in select d.*,x.value as metadata from public.whatsapp_default_templates d join lateral(select value from jsonb_array_elements(private.whatsapp_default_slots())where value->>'key'=d.slot)x on true where d.property_id=p_property loop
  if slot.state='customized'then continue;end if;
  select *into t from public.message_templates where property_id=p_property and name=slot.name and language='en_US'and provider_waba_id=(select waba_id from public.whatsapp_connections where id=cfg.connection_id);
  if t.id is null then all_ready:=false;if slot.kind='menu'then menu_ready:=false;end if;continue;end if;
  update public.whatsapp_default_templates set template_id=t.id,provider_id=t.provider_template_id,state=case when t.provider_status='APPROVED'and slot.kind='event'and t.category<>(case when slot.event_key='review_request'then'marketing'else'utility'end)then'needs_attention'when t.provider_status='APPROVED'and(case when slot.kind='event'then t.automation_supported else t.service_supported end)then'ready'when t.provider_status in('REJECTED','PAUSED','DISABLED')then'needs_attention'else'awaiting_approval'end,last_error=case when t.provider_status='APPROVED'and slot.kind='event'and t.category<>(case when slot.event_key='review_request'then'marketing'else'utility'end)then'Meta assigned a different category. Customize the template or review its purpose.'when t.provider_status='APPROVED'and not(case when slot.kind='event'then t.automation_supported else t.service_supported end)then'Template format or category needs attention.'else null end where property_id=p_property and whatsapp_default_templates.slot=slot.slot;
  if slot.kind='event'then
   select *into r from public.whatsapp_automation_rules where property_id=p_property and event_key=slot.event_key;
   if r.id is not null and(r.template_id is distinct from t.id or slot.rule_version is null or r.version is distinct from slot.rule_version)then update public.whatsapp_default_templates set state='customized'where property_id=p_property and whatsapp_default_templates.slot=slot.slot;continue;end if;
   keys:=t.parameter_names;desired:=cfg.enabled and(slot.metadata->>'activate')::boolean and t.provider_status='APPROVED'and t.automation_supported and t.category=case when slot.event_key='review_request'then'marketing'else'utility'end;
   if desired and exists(select 1 from jsonb_array_elements(t.provider_definition->'components')x where x->>'type'='HEADER'and x->>'format'='IMAGE')and not exists(select 1 from public.whatsapp_template_assets where property_id=p_property and provider_template_id=t.provider_template_id)then desired:=false;end if;
   if r.id is null or r.enabled is distinct from desired or r.template_fingerprint is distinct from t.provider_fingerprint then
    perform public.save_whatsapp_automation_rule(p_property,slot.event_key,coalesce(r.version,0),desired,t.id,keys,(slot.metadata->>'delay')::integer);
    update public.whatsapp_default_templates set rule_version=(select version from public.whatsapp_automation_rules where property_id=p_property and event_key=slot.event_key)where property_id=p_property and whatsapp_default_templates.slot=slot.slot;
   end if;
   if t.provider_status<>'APPROVED'or not t.automation_supported or t.category<>(case when slot.event_key='review_request'then'marketing'else'utility'end)then all_ready:=false;end if;
  elsif t.provider_status<>'APPROVED'or not t.service_supported then all_ready:=false;menu_ready:=false;end if;
 end loop;
 select *into menu from public.whatsapp_guest_menu where property_id=p_property;
 if menu.property_id is null or menu.version=cfg.menu_version then
  foreach cat in array array['My stay','Food & services','Hotel information','Reception']loop
   services:='[]';
   for slot in select d.*,x.value as metadata from public.whatsapp_default_templates d join lateral(select value from jsonb_array_elements(private.whatsapp_default_slots())where value->>'key'=d.slot)x on true where d.property_id=p_property and d.kind='menu'and x.value->>'group'=cat order by d.slot loop
    services:=services||jsonb_build_array(jsonb_build_object('id',md5(p_property::text||slot.slot)::uuid,'label',slot.metadata->>'label','action',slot.metadata->>'action','native_action',slot.metadata->>'native_action','enabled',slot.slot<>'menu_website'or coalesce((select data->>'website_url'from public.whatsapp_guest_settings where property_id=p_property),'')<>'','template_id',coalesce(slot.template_id::text,'')));
   end loop;
   categories:=categories||jsonb_build_array(jsonb_build_object('id',md5(p_property::text||cat)::uuid,'label',cat,'enabled',true,'services',services));
  end loop;
  metadata:=jsonb_build_object('intro','Welcome. How can we help with your stay?','items',jsonb_build_array(jsonb_build_object('action','reception','label','Talk to reception','enabled',true)),'categories',categories,'photos','[]'::jsonb);
  if menu.data is distinct from(metadata||coalesce((select jsonb_build_object('maps_url',data->>'maps_url','review_url',data->>'review_url','website_url',data->>'website_url')from public.whatsapp_guest_settings where property_id=p_property),'{}'::jsonb))or menu.enabled is distinct from(cfg.enabled and menu_ready)then
   perform public.save_whatsapp_guest_menu(p_property,coalesce(menu.version,0),cfg.enabled and menu_ready,metadata);
   update public.whatsapp_default_setup set menu_version=(select version from public.whatsapp_guest_menu where property_id=p_property)where property_id=p_property;
  end if;
 end if;
 select *into journey from public.whatsapp_journey_settings where property_id=p_property;
 if journey.property_id is null then perform public.save_whatsapp_journey(p_property,0,cfg.enabled,1,true,'photo');update public.whatsapp_default_setup set journey_managed=true where property_id=p_property;
 elsif journey.enabled is distinct from cfg.enabled then perform public.save_whatsapp_journey(p_property,journey.version,cfg.enabled,journey.required_documents,journey.self_checkin,journey.document_review_mode);end if;
 update public.whatsapp_default_setup set state=case when all_ready then'ready'else'awaiting_approval'end where property_id=p_property;
 perform set_config('request.jwt.claims',coalesce(old_claims,''),true);
 exception when others then perform set_config('request.jwt.claims',coalesce(old_claims,''),true);raise;
end $$;

create function public.toggle_whatsapp_defaults(p_property uuid,p_version integer,p_enabled boolean)returns void language plpgsql security definer set search_path=''as $$begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel administrator access required.'using errcode='42501';end if;
 update public.whatsapp_default_setup set enabled=p_enabled,version=version+1,next_check_at=now(),updated_at=now()where property_id=p_property and version=p_version and configured_by is not null;
 if not found then raise exception 'Complete setup or refresh before changing automation.'using errcode='40001';end if;
 perform private.apply_whatsapp_default_assignments(p_property);
end $$;

create function public.claim_whatsapp_default_setup()returns jsonb language plpgsql security definer set search_path=''as $$declare cfg public.whatsapp_default_setup;c public.whatsapp_connections;begin
 update public.whatsapp_default_setup set lease=null,locked_at=null where locked_at<now()-interval '3 minutes';
 select s.*into cfg from public.whatsapp_default_setup s join public.whatsapp_connections w on w.id=s.connection_id and w.status='active'join public.properties p on p.id=s.property_id and p.archived_at is null where s.configured_by is not null and s.welcome_image_url is not null and s.next_check_at<=now()and s.lease is null and private.tenant_is_active(p.tenant_id)and private.whatsapp_actor_allowed(s.property_id,s.configured_by)order by s.next_check_at,s.property_id limit 1 for update of s skip locked;
 if cfg.property_id is null then return null;end if;
 update public.whatsapp_default_setup set lease=gen_random_uuid(),locked_at=now(),state=case when state='queued'then'preparing'else state end where property_id=cfg.property_id returning *into cfg;
 select *into c from public.whatsapp_connections where id=cfg.connection_id;
 return to_jsonb(cfg)||jsonb_build_object('connection',to_jsonb(c),'links',(select data from public.whatsapp_guest_settings where property_id=cfg.property_id),'slots',(select jsonb_agg(to_jsonb(t))from public.whatsapp_default_templates t where property_id=cfg.property_id));
end $$;
create function public.finish_whatsapp_default_setup(p_property uuid,p_lease uuid,p_error text default null)returns void language plpgsql security definer set search_path=''as $$begin
 if not exists(select 1 from public.whatsapp_default_setup where property_id=p_property and lease=p_lease for update)then return;end if;
 if p_error is null then perform private.apply_whatsapp_default_assignments(p_property);end if;
 update public.whatsapp_default_setup set lease=null,locked_at=null,last_error=left(p_error,400),next_check_at=now()+case when p_error is not null then interval '5 minutes'when state='ready'then interval '15 minutes'else interval '1 minute'end where property_id=p_property and lease=p_lease;
end $$;
-- Template status sync automatically advances only managed assignments, preserving owner edits.
alter function public.sync_whatsapp_provider_templates(uuid,text,jsonb)rename to sync_whatsapp_provider_templates_before_defaults;
revoke all on function public.sync_whatsapp_provider_templates_before_defaults(uuid,text,jsonb)from public,anon,authenticated,service_role;
create function public.sync_whatsapp_provider_templates(p_connection uuid,p_waba text,p_templates jsonb)returns integer language plpgsql security definer set search_path=''as $$declare n integer;pid uuid;begin
 n:=public.sync_whatsapp_provider_templates_before_defaults(p_connection,p_waba,p_templates);select property_id into pid from public.whatsapp_connections where id=p_connection;
 perform private.apply_whatsapp_default_assignments(pid);return n;
end $$;
revoke all on function private.whatsapp_default_slots(),private.seed_whatsapp_defaults(uuid,uuid),private.initialize_whatsapp_defaults(),private.apply_whatsapp_default_assignments(uuid)from public,anon,authenticated,service_role;
revoke all on function public.whatsapp_default_workspace(uuid),public.toggle_whatsapp_defaults(uuid,integer,boolean)from public,anon;
grant execute on function public.whatsapp_default_workspace(uuid),public.toggle_whatsapp_defaults(uuid,integer,boolean)to authenticated;
revoke all on function public.save_whatsapp_default_setup(uuid,uuid,integer,jsonb,text),public.claim_whatsapp_default_setup(),public.finish_whatsapp_default_setup(uuid,uuid,text),public.sync_whatsapp_provider_templates(uuid,text,jsonb)from public,anon,authenticated;
grant execute on function public.save_whatsapp_default_setup(uuid,uuid,integer,jsonb,text),public.claim_whatsapp_default_setup(),public.finish_whatsapp_default_setup(uuid,uuid,text),public.sync_whatsapp_provider_templates(uuid,text,jsonb)to service_role;
create function public.record_whatsapp_default_template(p_property uuid,p_lease uuid,p_slot text,p_provider text,p_image text,p_error text)returns void language plpgsql security definer set search_path=''as $$begin
 if not exists(select 1 from public.whatsapp_default_setup where property_id=p_property and lease=p_lease for update)then raise exception 'Setup lease changed.'using errcode='40001';end if;
 if p_provider!~'^[0-9]+$'then raise exception 'Invalid provider template ID.'using errcode='22023';end if;
 update public.whatsapp_default_templates set provider_id=p_provider,state=case when p_error is null then'awaiting_approval'else'customized'end,last_error=left(p_error,400)where property_id=p_property and slot=p_slot;
 if not found then raise exception 'Unknown default template.'using errcode='22023';end if;
 if p_image is not null then
  if p_image is distinct from(select welcome_image_url from public.whatsapp_default_setup where property_id=p_property)then raise exception 'Welcome photo changed.'using errcode='22023';end if;
  insert into public.whatsapp_template_assets(property_id,provider_template_id,image_url)values(p_property,p_provider,p_image)on conflict(property_id,provider_template_id)do update set image_url=excluded.image_url;
 end if;
end $$;
revoke all on function public.record_whatsapp_default_template(uuid,uuid,text,text,text,text)from public,anon,authenticated;grant execute on function public.record_whatsapp_default_template(uuid,uuid,text,text,text,text)to service_role;
create function private.invoke_whatsapp_setup_worker()returns bigint language plpgsql security definer set search_path=''as $$declare c private.whatsapp_worker_configuration;secret text;request bigint;begin
 select *into c from private.whatsapp_worker_configuration where id=true and enabled;if c.id is null then return null;end if;
 if not exists(select 1 from public.whatsapp_default_setup where configured_by is not null and next_check_at<=now())then return null;end if;
 select decrypted_secret into secret from vault.decrypted_secrets where id=c.secret_id;
 select net.http_post(url:=c.origin||'/functions/v1/whatsapp-setup-worker',headers:=jsonb_build_object('Content-Type','application/json','X-Worker-Secret',secret),body:='{}',timeout_milliseconds:=120000)into request;return request;
end $$;
revoke all on function private.invoke_whatsapp_setup_worker()from public,anon,authenticated,service_role;
select cron.schedule('hospitality-whatsapp-setup','* * * * *','select private.invoke_whatsapp_setup_worker()');
