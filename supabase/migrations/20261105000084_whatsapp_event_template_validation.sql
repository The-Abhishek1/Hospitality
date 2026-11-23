-- Prevent activating rules that can never render their chosen event's fields.
create function private.whatsapp_event_field_allowed(p_event text,p_field text)returns boolean
language sql immutable set search_path=''as $$
 select p_field in('guest_name','hotel_name','booking_reference','check_in','check_out','hotel_phone','room_name','event_label','order_reference','request_title','amount','currency','invoice_number','portal_url','review_url')
 and(p_field<>'order_reference'or p_event in('order_placed','order_preparing','order_ready','order_served','order_cancelled'))
 and(p_field<>'request_title'or p_event in('request_received','request_started','request_completed','request_cancelled'))
 and(p_field<>'invoice_number'or p_event='invoice_issued')
 and(p_field<>'review_url'or p_event='review_request')
 and(p_field<>'portal_url'or p_event<>'booking_cancelled');
$$;
revoke all on function private.whatsapp_event_field_allowed(text,text)from public,anon,authenticated,service_role;

create or replace function public.save_whatsapp_automation_rule(p_property uuid,p_event text,p_version integer,p_enabled boolean,p_template uuid,p_keys jsonb,p_delay integer)returns void
language plpgsql security definer set search_path=''as $$
declare r public.whatsapp_automation_rules;t public.message_templates;tenant uuid;k text;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel administrator access required'using errcode='42501';end if;
 select tenant_id into tenant from public.properties where id=p_property for update;
 if not exists(select 1 from jsonb_array_elements(public.whatsapp_automation_catalog())x where x->>'key'=p_event)or p_enabled is null or p_delay is null or p_delay not between 0 and 10080 or jsonb_typeof(p_keys)is distinct from'array'then raise exception 'Invalid automation rule'using errcode='22023';end if;
 select *into r from public.whatsapp_automation_rules where property_id=p_property and event_key=p_event;
 if coalesce(r.version,0)<>p_version then raise exception 'Rule changed. Refresh before saving.'using errcode='40001';end if;
 select *into t from public.message_templates where id=p_template and property_id=p_property;
 if p_enabled and(t.id is null or t.status<>'approved'or not t.automation_supported or t.provider_checked_at<now()-interval '24 hours'or t.provider_waba_id is distinct from(select waba_id from public.whatsapp_connections where property_id=p_property and status='active')or t.category<>case when p_event='review_request'then'marketing'else'utility'end)then raise exception 'Sync and select a compatible approved template from this hotel’s current WhatsApp account.'using errcode='22023';end if;
 if p_enabled and jsonb_array_length(p_keys)<>jsonb_array_length(t.parameter_names)then raise exception 'Map every template parameter.'using errcode='22023';end if;
 for k in select jsonb_array_elements_text(p_keys)loop
  if k not in('guest_name','hotel_name','booking_reference','check_in','check_out','hotel_phone','room_name','event_label','order_reference','request_title','amount','currency','invoice_number','portal_url','review_url')then raise exception 'Unsupported template variable'using errcode='22023';end if;
  if p_enabled and private.whatsapp_event_field_allowed(p_event,k)is not true then raise exception 'This template field is unavailable for the chosen event: %',k using errcode='22023';end if;
 end loop;
 if p_enabled and exists(select 1 from jsonb_array_elements_text(t.parameter_names)v(name)where name in('order_reference','request_title','invoice_number','review_url','portal_url')and not private.whatsapp_event_field_allowed(p_event,name))then raise exception 'Choose a template whose named fields are available for this event.'using errcode='22023';end if;
 insert into public.whatsapp_automation_rules(property_id,tenant_id,event_key,enabled,template_id,template_fingerprint,parameter_keys,delay_minutes,updated_by)
 values(p_property,tenant,p_event,p_enabled,t.id,t.provider_fingerprint,p_keys,p_delay,auth.uid())
 on conflict(property_id,event_key)do update set enabled=excluded.enabled,template_id=excluded.template_id,template_fingerprint=excluded.template_fingerprint,parameter_keys=excluded.parameter_keys,delay_minutes=excluded.delay_minutes,updated_by=auth.uid(),updated_at=now(),version=whatsapp_automation_rules.version+1;
 insert into public.whatsapp_automation_audit(property_id,tenant_id,actor,action,details)values(p_property,tenant,auth.uid(),'rule_saved',jsonb_build_object('event',p_event,'enabled',p_enabled,'template',t.id));
end $$;
