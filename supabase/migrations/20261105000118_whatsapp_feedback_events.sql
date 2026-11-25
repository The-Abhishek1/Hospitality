alter function public.whatsapp_automation_catalog()rename to whatsapp_automation_catalog_before_feedback;
revoke all on function public.whatsapp_automation_catalog_before_feedback()from public,anon,authenticated,service_role;
create function public.whatsapp_automation_catalog()returns jsonb language sql immutable security definer set search_path=''as $$
 select public.whatsapp_automation_catalog_before_feedback()||jsonb_build_array(jsonb_build_object('key','order_feedback','label','Food feedback after delivery','group','Dining','scheduled',false),jsonb_build_object('key','request_feedback','label','Feedback after service completion','group','Services','scheduled',false))
$$;
revoke all on function public.whatsapp_automation_catalog()from public,anon;grant execute on function public.whatsapp_automation_catalog()to authenticated,service_role;
do $$declare d text;begin
 d:=pg_get_functiondef('private.whatsapp_event_field_allowed(text,text)'::regprocedure);d:=replace(d,'''order_cancelled'')','''order_cancelled'',''order_feedback'')');d:=replace(d,'''request_cancelled'')','''request_cancelled'',''request_feedback'')');execute d;
end $$;
create function private.capture_feedback_event()returns trigger language plpgsql security definer set search_path=''as $$begin
 if tg_table_name='orders'and new.status='served'and old.status is distinct from new.status then
  perform private.capture_whatsapp_event(new.property_id,new.reservation_id,'order_feedback',new.id::text,'orders',new.id,'served',jsonb_build_object('order_reference',upper(left(replace(new.id::text,'-',''),8))));
 elsif tg_table_name='guest_requests'and new.status='completed'and old.status is distinct from new.status then
  perform private.capture_whatsapp_event(new.property_id,new.reservation_id,'request_feedback',new.id::text,'guest_requests',new.id,'completed',jsonb_build_object('request_title',new.title));
 end if;return new;
end $$;
create trigger food_feedback_event after update of status on public.orders for each row execute function private.capture_feedback_event();
create trigger service_feedback_event after update of status on public.guest_requests for each row execute function private.capture_feedback_event();
revoke all on function private.capture_feedback_event()from public,anon,authenticated,service_role;
-- Default services use native chat actions and only documents, food and bills need a helper page.
do $$declare d text;begin
 d:=pg_get_functiondef('private.queue_whatsapp_guest_reply_before_journey(uuid,uuid,text,boolean,uuid,text)'::regprocedure);
 d:=replace(d,'case s->>''action''when''documents''','case coalesce(s->>''native_action'',s->>''action'')when''bill''then''?view=bill''when''documents''');execute d;
end $$;
alter function private.queue_whatsapp_guest_reply(uuid,uuid,text,boolean,uuid,text)rename to queue_whatsapp_guest_reply_before_defaults;
revoke all on function private.queue_whatsapp_guest_reply_before_defaults(uuid,uuid,text,boolean,uuid,text)from public,anon,authenticated,service_role;
create function private.queue_whatsapp_guest_reply(p_conversation uuid,p_request uuid,p_action text,p_automatic boolean,p_source uuid,p_origin text)returns uuid language plpgsql security definer set search_path=''as $$
declare mid uuid;native text;begin
 if p_automatic and private.poststay_reservation(p_conversation)is not null then perform private.handle_whatsapp_journey(p_conversation,p_source,'menu',p_origin);return null;end if;
 mid:=private.queue_whatsapp_guest_reply_before_defaults(p_conversation,p_request,p_action,p_automatic,p_source,p_origin);
 if p_automatic and mid is not null and p_action~'^service:[a-f0-9-]{36}$'then
  select x->>'native_action'into native from public.whatsapp_guest_menu m cross join lateral jsonb_array_elements(m.data->'categories')k cross join lateral jsonb_array_elements(k->'services')x where m.property_id=(select property_id from public.conversations where id=p_conversation)and m.enabled and k->>'enabled'='true'and x->>'enabled'='true'and x->>'id'=split_part(p_action,':',2);
  if native in('checkin','checkout','services')then perform private.handle_whatsapp_journey(p_conversation,p_source,native,p_origin);end if;
 end if;return mid;
end $$;
revoke all on function private.queue_whatsapp_guest_reply(uuid,uuid,text,boolean,uuid,text)from public,anon,authenticated,service_role;
