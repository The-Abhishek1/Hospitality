-- A bounded, permission-checked view of exceptions shown beside the hotel's master switch.
create function public.whatsapp_control_status(p_property uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $$begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel administrator access required.'using errcode='42501';end if;
 return jsonb_build_object(
  'paused_count',(select count(*)from public.conversations where property_id=p_property and human_handoff and status='open'),
  'paused_chats',coalesce((select jsonb_agg(to_jsonb(x))from(select id,coalesce(nullif(contact_name,''),'+'||wa_contact_id)as name from public.conversations where property_id=p_property and human_handoff and status='open'order by last_message_at desc,id limit 5)x),'[]'::jsonb),
  'blocked_count',(select count(*)from public.whatsapp_automation_events where property_id=p_property and state='blocked'),
  'blocked_events',coalesce((select jsonb_agg(to_jsonb(x))from(select id,event_key,reason,reservation_id from public.whatsapp_automation_events where property_id=p_property and state='blocked'order by created_at desc,id limit 5)x),'[]'::jsonb));
end $$;
revoke all on function public.whatsapp_control_status(uuid)from public,anon;
grant execute on function public.whatsapp_control_status(uuid)to authenticated;
