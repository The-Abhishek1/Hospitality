-- Manual approved photo templates use the same image component as event/menu delivery.
create or replace function public.inbox_send(p_conversation uuid,p_request uuid,p_body text default null,p_template uuid default null)returns uuid
language plpgsql security definer set search_path=''as $$
declare c public.conversations;m uuid;t public.message_templates;w public.whatsapp_connections;image_url text;components jsonb:='[]';
begin
 c:=private.lock_conversation(p_conversation,'whatsapp.use');
 if p_request is null then raise exception 'Reload the reply form and try again.'using errcode='22023';end if;
 select id into m from public.messages where conversation_id=c.id and creation_request_id=p_request;
 if found then return m;end if;
 perform private.staff_share(c.property_id);
 select *into w from public.whatsapp_connections where id=c.connection_id;
 if w.status is distinct from'active'then raise exception 'WhatsApp messaging is not enabled for this hotel.'using errcode='22023';end if;
 if c.status<>'open'then raise exception 'Reopen the conversation before replying.'using errcode='22023';end if;
 if private.is_opted_out(c.property_id,c.wa_contact_id)then raise exception 'This contact opted out. Messaging is blocked until they opt in again.'using errcode='22023';end if;
 if p_template is not null then
  select *into t from public.message_templates where id=p_template and property_id=c.property_id and status='approved';
  if t.id is null then raise exception 'Choose an approved template for this hotel.'using errcode='22023';end if;
  if t.provider_template_id is not null and(not t.automation_supported or t.provider_waba_id is distinct from w.waba_id or t.provider_checked_at is null or t.provider_checked_at<now()-interval '24 hours')then raise exception 'Sync and choose a compatible approved template for this hotel.'using errcode='22023';end if;
  if strpos(t.body,'{{')>0 or jsonb_array_length(t.parameter_names)>0 then raise exception 'Templates with guest fields are sent through WhatsApp Automation.'using errcode='22023';end if;
  if exists(select 1 from jsonb_array_elements(t.provider_definition->'components')h where h->>'type'='HEADER'and h->>'format'='IMAGE')then
   select a.image_url into image_url from public.whatsapp_template_assets a where a.property_id=c.property_id and a.provider_template_id=t.provider_template_id;
   if image_url is null then raise exception 'Choose this template’s delivery image in WhatsApp Automation → Templates first.'using errcode='22023';end if;
   components:=jsonb_build_array(jsonb_build_object('type','header','parameters',jsonb_build_array(jsonb_build_object('type','image','image',jsonb_build_object('link',image_url)))));
  end if;
 else
  if length(trim(coalesce(p_body,'')))not between 1 and 4096 then raise exception 'Write a reply between 1 and 4096 characters.'using errcode='22023';end if;
  if c.last_inbound_at is null or c.last_inbound_at<=now()-interval '24 hours'then raise exception 'The reply window has closed. Choose an approved template.'using errcode='22023';end if;
 end if;
 insert into public.messages(tenant_id,property_id,conversation_id,direction,type,body,template_id,status,sent_by,creation_request_id,template_components,guest_sender_id)
 values(c.tenant_id,c.property_id,c.id,'out',case when p_template is null then'text'else'template'end,case when p_template is null then trim(p_body)else t.body end,p_template,'queued',auth.uid(),p_request,components,w.phone_number_id)returning id into m;
 update public.conversations set last_message_at=now()where id=c.id;return m;
end $$;

alter function private.inbox_delivery_error(uuid)rename to inbox_delivery_error_before_photo_template;
revoke all on function private.inbox_delivery_error_before_photo_template(uuid)from public,anon,authenticated,service_role;
create function private.inbox_delivery_error(p_message uuid)returns text
language plpgsql stable security definer set search_path=''as $$
declare m public.messages;t public.message_templates;why text;image_url text;
begin
 why:=private.inbox_delivery_error_before_photo_template(p_message);if why is not null then return why;end if;
 select *into m from public.messages where id=p_message;
 if m.type<>'template'or m.automation_event_id is not null or m.outbound_payload is not null then return null;end if;
 select *into t from public.message_templates where id=m.template_id;
 if t.provider_template_id is not null and(not t.automation_supported or t.provider_checked_at is null or t.provider_checked_at<now()-interval '24 hours'or t.provider_waba_id is distinct from(select w.waba_id from public.conversations c join public.whatsapp_connections w on w.id=c.connection_id where c.id=m.conversation_id))then return 'Template approval needs to be synchronized.';end if;
 if m.guest_sender_id is not null and m.guest_sender_id is distinct from(select w.phone_number_id from public.conversations c join public.whatsapp_connections w on w.id=c.connection_id where c.id=m.conversation_id)then return 'Hotel sender changed. Create a new message.';end if;
 if exists(select 1 from jsonb_array_elements(t.provider_definition->'components')h where h->>'type'='HEADER'and h->>'format'='IMAGE')then
  select a.image_url into image_url from public.whatsapp_template_assets a where a.property_id=m.property_id and a.provider_template_id=t.provider_template_id;
  if image_url is null or m.template_components#>>'{0,parameters,0,image,link}'is distinct from image_url then return 'Template photo changed or is missing. Choose its image and send a fresh reply.';end if;
 end if;
 return null;
end $$;
revoke all on function private.inbox_delivery_error(uuid)from public,anon,authenticated,service_role;

alter function public.inbox_workspace(uuid,jsonb)rename to inbox_workspace_before_photo_templates;
revoke all on function public.inbox_workspace_before_photo_templates(uuid,jsonb)from public,anon,authenticated,service_role;
create function public.inbox_workspace(p_property uuid,p_filters jsonb default '{}')returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare d jsonb;templates jsonb;messages jsonb;
begin
 d:=public.inbox_workspace_before_photo_templates(p_property,p_filters);
 select coalesce(jsonb_agg(v||jsonb_build_object('image_url',a.image_url,'supported',coalesce((v->>'supported')::boolean,false)and(t.provider_template_id is null or(t.provider_checked_at>now()-interval '24 hours'and t.provider_waba_id=(select waba_id from public.whatsapp_connections where property_id=p_property and status='active')))and(not exists(select 1 from jsonb_array_elements(t.provider_definition->'components')h where h->>'type'='HEADER'and h->>'format'='IMAGE')or a.image_url is not null))order by n),'[]')into templates
 from jsonb_array_elements(d->'templates')with ordinality x(v,n)join public.message_templates t on t.id=(v->>'id')::uuid and t.property_id=p_property left join public.whatsapp_template_assets a on a.property_id=t.property_id and a.provider_template_id=t.provider_template_id;
 select coalesce(jsonb_agg(v||case when m.type='template'and m.outbound_payload is null and jsonb_array_length(coalesce(m.template_components,'[]'))>0 then jsonb_build_object('outbound_payload',jsonb_build_object('type','template','template',jsonb_build_object('components',m.template_components)))else'{}'::jsonb end order by n),'[]')into messages
 from jsonb_array_elements(d->'messages')with ordinality x(v,n)join public.messages m on m.id=(v->>'id')::uuid and m.property_id=p_property;
 return d||jsonb_build_object('templates',templates,'messages',messages);
end $$;
revoke all on function public.inbox_workspace(uuid,jsonb)from public,anon;
grant execute on function public.inbox_workspace(uuid,jsonb)to authenticated;
