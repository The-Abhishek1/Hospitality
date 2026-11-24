-- Separate one-time booking welcomes from admission settings; preserve consent and per-booking deduplication.

create or replace function private.whatsapp_automation_error(p_event uuid)returns text language plpgsql stable security definer set search_path='' as $$
declare why text;e public.whatsapp_automation_events;c public.conversations;t public.message_templates;b private.whatsapp_booking_contacts;
begin
 why:=private.whatsapp_automation_error_before_journey(p_event);
 select *into e from public.whatsapp_automation_events where id=p_event;
 if e.event_key='booking_confirmed'then
  select *into b from private.whatsapp_booking_contacts where reservation_id=e.reservation_id and guest_id=e.guest_id;
  if b.reservation_id is null then return coalesce(nullif(why,'Guest stay-update permission missing or revoked.'),'Booking welcome needs recorded prior contact permission.');end if;
  if why is null or why='Guest stay-update permission missing or revoked.'then
   select *into c from public.conversations where id=b.conversation_id;
   if b.phone is distinct from(select private.campaign_phone(phone)from public.guests where id=e.guest_id)or c.guest_id is distinct from e.guest_id or c.wa_contact_id is distinct from b.phone then return 'Guest contact binding changed.';end if;
   if private.is_opted_out(e.property_id,b.phone)or c.status<>'open'or c.human_handoff then return 'Guest opted out or conversation handed to reception.';end if;
   if not exists(select 1 from public.whatsapp_connections where id=c.connection_id and property_id=e.property_id and status='active'and(e.sender_phone_id is null or phone_number_id=e.sender_phone_id))then return 'Hotel sender is inactive or changed.';end if;
   select mt.*into t from public.message_templates mt join public.whatsapp_automation_rules wr on wr.template_id=mt.id where wr.id=e.rule_id and mt.property_id=e.property_id and mt.provider_fingerprint=wr.template_fingerprint and mt.provider_waba_id=(select waba_id from public.whatsapp_connections where id=c.connection_id);
   if t.id is null or t.status<>'approved'or not t.automation_supported or t.provider_checked_at<now()-interval '24 hours'then return 'Approved template changed, unavailable or sync is stale.';end if;
   why:=null;
  end if;
 end if;
 if why is null and e.event_key='documents_approved'and private.journey_document_error(e.reservation_id)is not null then return 'Required document review is no longer complete.';end if;
 if why is null and e.message_id is not null and exists(select 1 from public.messages m cross join lateral jsonb_array_elements(coalesce(m.template_components,'[]'))h where m.id=e.message_id and h->>'type'='header'and h#>>'{parameters,0,image,link}'is distinct from(select a.image_url from public.whatsapp_template_assets a join public.message_templates mt on mt.provider_template_id=a.provider_template_id and mt.property_id=a.property_id join public.whatsapp_automation_rules wr on wr.template_id=mt.id where wr.id=e.rule_id))then return 'Template delivery image changed.';end if;
 if why is null and exists(select 1 from public.message_templates mt join public.whatsapp_automation_rules wr on wr.template_id=mt.id where wr.id=e.rule_id and exists(select 1 from jsonb_array_elements(mt.provider_definition->'components')h where h->>'type'='HEADER'and h->>'format'='IMAGE')and not exists(select 1 from public.whatsapp_template_assets a where a.property_id=e.property_id and a.provider_template_id=mt.provider_template_id))then return 'Upload a delivery image for this template.';end if;
 return why;
end $$;

create or replace function public.dispatch_whatsapp_automations(p_limit integer default 50,p_portal_origin text default null)returns integer
language plpgsql security definer set search_path=''as $$
declare item record;e public.whatsapp_automation_events;r public.reservations;rule public.whatsapp_automation_rules;t public.message_templates;a public.whatsapp_guest_authorizations;
 due timestamptz;expires timestamptz;why text;vars jsonb;params jsonb;components jsonb;body text;k text;value text;i integer;name text;token text;mid uuid;n integer:=0;phone text;match text[];delivery_conversation uuid;
begin
 -- Schedule current/future stays only. Enabling a rule never backfills an old milestone.
 for item in select rr.*,s.timezone,coalesce(ps.check_in_time,'14:00'::time)as in_time,coalesce(ps.check_out_time,'11:00'::time)as out_time,wr.id as rule,wr.event_key,wr.delay_minutes,wr.updated_at as enabled_at,wr.version as rule_version,private.whatsapp_due_at(wr.event_key,rr.check_in,rr.check_out,rr.checked_out_at,s.timezone,coalesce(ps.check_in_time,'14:00'::time),coalesce(ps.check_out_time,'11:00'::time),wr.delay_minutes)as scheduled_due
 from public.whatsapp_automation_rules wr join public.reservations rr on rr.property_id=wr.property_id join public.properties s on s.id=rr.property_id left join public.property_settings ps on ps.property_id=rr.property_id
 where wr.enabled and private.tenant_is_active(rr.tenant_id)and((wr.event_key='arrival_reminder'and rr.status='confirmed')or(wr.event_key='checkout_reminder'and rr.status='checked_in')or(wr.event_key='review_request'and rr.status='checked_out'))
 and rr.check_out>=(now()at time zone s.timezone)::date-7 and rr.check_in<=(now()at time zone s.timezone)::date+14
 and(case wr.event_key when'arrival_reminder'then((rr.check_in+coalesce(ps.check_in_time,'14:00'::time))at time zone s.timezone)-make_interval(mins=>wr.delay_minutes)when'checkout_reminder'then((rr.check_out+coalesce(ps.check_out_time,'11:00'::time))at time zone s.timezone)-make_interval(mins=>wr.delay_minutes)else coalesce(rr.checked_out_at,(rr.check_out+coalesce(ps.check_out_time,'11:00'::time))at time zone s.timezone)+make_interval(mins=>wr.delay_minutes)end)>=wr.updated_at
 and(case wr.event_key when'arrival_reminder'then((rr.check_in+coalesce(ps.check_in_time,'14:00'::time))at time zone s.timezone)+interval '1 hour'when'checkout_reminder'then((rr.check_out+coalesce(ps.check_out_time,'11:00'::time))at time zone s.timezone)+interval '1 hour'else coalesce(rr.checked_out_at,(rr.check_out+coalesce(ps.check_out_time,'11:00'::time))at time zone s.timezone)+make_interval(mins=>wr.delay_minutes)+interval '24 hours'end)>now()
 and not exists(select 1 from public.whatsapp_automation_events ae where ae.property_id=rr.property_id and ae.event_key=wr.event_key and ae.dedup_key=rr.id::text||':'||rr.check_in::text||':'||rr.check_out::text||':'||wr.version::text||':'||extract(epoch from private.whatsapp_due_at(wr.event_key,rr.check_in,rr.check_out,rr.checked_out_at,s.timezone,coalesce(ps.check_in_time,'14:00'::time),coalesce(ps.check_out_time,'11:00'::time),wr.delay_minutes))::text)
 and not exists(select 1 from public.whatsapp_automation_events prior join public.messages sent on sent.id=prior.message_id where prior.property_id=rr.property_id and prior.reservation_id=rr.id and prior.guest_id=rr.guest_id and prior.event_key=wr.event_key and prior.payload->>'check_in'=rr.check_in::text and prior.payload->>'check_out'=rr.check_out::text and(sent.status in('sending','sent','delivered','read')or sent.delivery_uncertain))
 order by rr.check_in,rr.id limit 500 loop
  due:=item.scheduled_due;
  expires:=case item.event_key when'arrival_reminder'then((item.check_in+item.in_time)at time zone item.timezone)+interval '1 hour'when'checkout_reminder'then((item.check_out+item.out_time)at time zone item.timezone)+interval '1 hour'else due+interval '24 hours'end;
  if due>=item.enabled_at and expires>now()then perform private.capture_whatsapp_event(item.property_id,item.id,item.event_key,item.id::text||':'||item.check_in::text||':'||item.check_out::text||':'||item.rule_version::text||':'||extract(epoch from due)::text,'reservations',item.id,item.status,'{}',due,expires);end if;
 end loop;
 for e in select *from public.whatsapp_automation_events where state in('pending','blocked')and due_at<=now()and next_check_at<=now()order by due_at,id limit greatest(1,least(200,p_limit))for update skip locked loop
  why:=private.whatsapp_automation_error(e.id);
  if why is not null then
   update public.whatsapp_automation_events set state=case when expires_at<=now()or why in('Rule paused or changed.','Stay or guest changed.','Stay is no longer eligible.','Stay dates changed.','Stay schedule changed.','Source status changed.')then'skipped'else'blocked'end,reason=why,next_check_at=now()+interval '1 minute'where id=e.id;continue;
  end if;
  select *into r from public.reservations where id=e.reservation_id;
  select *into rule from public.whatsapp_automation_rules where id=e.rule_id;
  select *into t from public.message_templates where id=rule.template_id;
  select *into a from public.whatsapp_guest_authorizations where property_id=e.property_id and guest_id=e.guest_id;
  delivery_conversation:=a.conversation_id;
  if e.event_key='booking_confirmed'then
   select conversation_id into delivery_conversation from private.whatsapp_booking_contacts where reservation_id=r.id;
  end if;
  vars:=e.payload||jsonb_build_object('check_in_time',coalesce((select check_in_time::text from public.property_settings where property_id=e.property_id),'14:00'),'check_out_time',coalesce((select check_out_time::text from public.property_settings where property_id=e.property_id),'11:00'));token:=null;
  if rule.parameter_keys?'room_name'then vars:=vars||jsonb_build_object('room_name',private.whatsapp_reservation_room_name(r.id));end if;
  if e.source_table='orders'then vars:=vars||jsonb_build_object('amount',(select total::text from public.orders where id=e.source_id),'order_summary',(select left(string_agg(quantity::text||' × '||name_snapshot,', 'order by id),1500)from public.order_items where order_id=e.source_id));end if;
  if rule.parameter_keys?'review_url'then vars:=vars||jsonb_build_object('review_url',(select data->>'review_url'from public.whatsapp_guest_settings where property_id=e.property_id));end if;
  if rule.parameter_keys?'portal_url'then
   if p_portal_origin is null or not private.whatsapp_studio_url(p_portal_origin,false)or p_portal_origin~'[?#]'or r.status in('cancelled','no_show')then
    update public.whatsapp_automation_events set state='blocked',reason='Secure guest portal origin not configured.',next_check_at=now()+interval '1 minute'where id=e.id;continue;
   end if;
   token:=encode(extensions.gen_random_bytes(32),'hex');
   insert into public.guest_access_tokens(tenant_id,property_id,reservation_id,token_hash,expires_at)values(e.tenant_id,e.property_id,r.id,encode(sha256(convert_to(token,'utf8')),'hex'),now()+interval '7 days');
   vars:=vars||jsonb_build_object('portal_url',rtrim(p_portal_origin,'/')||'/s/'||token||case when e.event_key in('booking_confirmed','documents_rejected','documents_received')then'?view=documents&via=whatsapp'when e.event_key in('invoice_issued','payment_received','checkout_reminder')then'?view=bill&via=whatsapp'else''end);
  end if;
  params:='[]';body:=t.body;why:=null;
  if jsonb_array_length(rule.parameter_keys)<>jsonb_array_length(t.parameter_names)then why:='Template variable mapping changed.';end if;
  for i in 0..jsonb_array_length(t.parameter_names)-1 loop
   k:=rule.parameter_keys->>i;name:=t.parameter_names->>i;value:=regexp_replace(trim(coalesce(vars->>k,'')),'[\n\r\t]+',' ','g');
   if value=''or length(value)>2000 then why:='Required variable unavailable: '||coalesce(k,'unknown');exit;end if;
   params:=params||jsonb_build_array(jsonb_build_object('type','text','text',value)||case when name~'^[a-z_]'then jsonb_build_object('parameter_name',name)else'{}'::jsonb end);
   for match in select regexp_matches(body,'(\{\{\s*'||name||'\s*\}\})','g')loop body:=replace(body,match[1],value);end loop;
  end loop;
  if why is not null then
   if token is not null then delete from public.guest_access_tokens where reservation_id=r.id and token_hash=encode(sha256(convert_to(token,'utf8')),'hex');end if;
   update public.whatsapp_automation_events set state='blocked',reason=why,next_check_at=now()+interval '1 minute'where id=e.id;continue;
  end if;
  components:=case when jsonb_array_length(params)>0 then jsonb_build_array(jsonb_build_object('type','body','parameters',params))else'[]'::jsonb end;
  if exists(select 1 from jsonb_array_elements(t.provider_definition->'components')h where h->>'type'='HEADER'and h->>'format'='IMAGE')then
   components:=jsonb_build_array(jsonb_build_object('type','header','parameters',jsonb_build_array(jsonb_build_object('type','image','image',jsonb_build_object('link',(select image_url from public.whatsapp_template_assets where property_id=e.property_id and provider_template_id=t.provider_template_id))))))||components;
  end if;
  select wc.phone_number_id into phone from public.conversations cv join public.whatsapp_connections wc on wc.id=cv.connection_id where cv.id=delivery_conversation;
  insert into public.messages(tenant_id,property_id,conversation_id,direction,type,body,template_id,status,automation_event_id,template_components)
  values(e.tenant_id,e.property_id,delivery_conversation,'out','template',body,t.id,'queued',e.id,components)on conflict(automation_event_id)where automation_event_id is not null do nothing returning id into mid;
  if mid is null then select id into mid from public.messages where automation_event_id=e.id;end if;
  update public.whatsapp_automation_events set state='queued',reason=null,message_id=mid,sender_phone_id=phone where id=e.id;
  update public.conversations set last_message_at=now()where id=delivery_conversation;n:=n+1;
 end loop;
 return n;
end $$;

create or replace function public.booking_welcome_status(p_property uuid,p_reservation uuid default null)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare r public.reservations;rule public.whatsapp_automation_rules;t public.message_templates;e public.whatsapp_automation_events;m public.messages;state text:='ready';why text;permission boolean;journey boolean;
begin
 if not private.has_permission(p_property,'reservations.read')then raise exception 'Reservation access required.'using errcode='42501';end if;
 if p_reservation is not null then select *into r from public.reservations where id=p_reservation and property_id=p_property;if r.id is null then raise exception 'Reservation not found.'using errcode='P0002';end if;end if;
 select enabled into journey from public.whatsapp_journey_settings where property_id=p_property;
 select *into rule from public.whatsapp_automation_rules where property_id=p_property and event_key='booking_confirmed';select *into t from public.message_templates where id=rule.template_id and property_id=p_property;
 if p_reservation is not null then
  select *into e from public.whatsapp_automation_events where property_id=p_property and reservation_id=p_reservation and event_key='booking_confirmed'order by created_at desc limit 1;
  select *into m from public.messages where id=e.message_id;
  permission:=exists(select 1 from private.whatsapp_booking_contacts where reservation_id=r.id and property_id=p_property and guest_id=r.guest_id);
 end if;
 if m.status in('sent','delivered','read')then state:=m.status;why:='Booking welcome sent.';
 elsif m.status='sending'then state:='sending';why:='Booking welcome is being sent.';
 elsif m.status='failed'then state:='failed';why:=coalesce(m.error,'Delivery failed. Review WhatsApp delivery history.');
 elsif coalesce(rule.enabled,false)is not true then state:='off';why:='Booking welcome is off. Assign an approved template and activate this event.';
 elsif t.id is null then state:='template';why:='No booking-welcome template is assigned.';
 elsif not(rule.parameter_keys?'portal_url')then state:='template';why:='Choose a welcome template containing the personal guest-task link.';
 elsif not exists(select 1 from public.whatsapp_connections where property_id=p_property and status='active')then state:='connection';why:='Connect this hotel’s WhatsApp number.';
 elsif t.status<>'approved'or not t.automation_supported or t.provider_checked_at<now()-interval '24 hours'then state:='template';why:='Sync and choose a compatible approved template.';
 elsif p_reservation is not null and not permission then state:='permission';why:='Record the guest’s prior permission for this one booking welcome.';
 elsif e.id is not null then
  why:=private.whatsapp_automation_error(e.id);
  if why is not null then state:='blocked';elsif m.status='queued'then state:='queued';why:='Queued for automatic WhatsApp delivery.';else state:=e.state;why:=coalesce(e.reason,'Booking welcome is waiting for delivery.');end if;
 elsif p_reservation is not null then state:='not_queued';why:='Welcome is configured, but no message was queued for this booking. Send its welcome once below.';
 else why:='Ready: a booking welcome with the document link is queued automatically when prior contact permission is recorded.';
 end if;
 return jsonb_build_object('state',state,'reason',why,'template',t.name,'permission_recorded',permission,'can_configure',private.has_permission(p_property,'staff.manage'),'can_send',private.has_permission(p_property,'reservations.write')and r.status='confirmed'and permission and state in('not_queued','blocked','pending')and r.created_at>now()-interval '24 hours','event_id',e.id,'message_id',m.id);
end $$;

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
  if k not in('guest_name','hotel_name','booking_reference','check_in','check_out','hotel_phone','room_name','event_label','order_reference','request_title','amount','currency','invoice_number','portal_url','review_url','check_in_time','check_out_time','order_summary')then raise exception 'Unsupported template variable'using errcode='22023';end if;
  if p_enabled and private.whatsapp_event_field_allowed(p_event,k)is not true then raise exception 'This template field is unavailable for the chosen event: %',k using errcode='22023';end if;
 end loop;
 if p_enabled and exists(select 1 from jsonb_array_elements_text(t.parameter_names)v(name)where name in('order_summary','order_reference','request_title','invoice_number','review_url','portal_url')and not private.whatsapp_event_field_allowed(p_event,name))then raise exception 'Choose a template whose named fields are available for this event.'using errcode='22023';end if;
 if p_enabled and exists(select 1 from jsonb_array_elements(t.provider_definition->'components')h where h->>'type'='HEADER'and h->>'format'='IMAGE')and not exists(select 1 from public.whatsapp_template_assets a where a.property_id=p_property and a.provider_template_id=t.provider_template_id)then raise exception 'Choose a delivery photo for this template before activating it.'using errcode='22023';end if;
 if p_enabled and p_event='booking_confirmed'and not(p_keys?'portal_url')then raise exception 'Choose a booking welcome with the personal document-upload link.'using errcode='22023';end if;
 if p_event='booking_confirmed'and p_delay<>0 then raise exception 'Booking welcomes send after confirmation without a delay.'using errcode='22023';end if;
 insert into public.whatsapp_automation_rules(property_id,tenant_id,event_key,enabled,template_id,template_fingerprint,parameter_keys,delay_minutes,updated_by)
 values(p_property,tenant,p_event,p_enabled,t.id,t.provider_fingerprint,p_keys,p_delay,auth.uid())
 on conflict(property_id,event_key)do update set enabled=excluded.enabled,template_id=excluded.template_id,template_fingerprint=excluded.template_fingerprint,parameter_keys=excluded.parameter_keys,delay_minutes=excluded.delay_minutes,updated_by=auth.uid(),updated_at=now(),version=whatsapp_automation_rules.version+1;
 insert into public.whatsapp_automation_audit(property_id,tenant_id,actor,action,details)values(p_property,tenant,auth.uid(),'rule_saved',jsonb_build_object('event',p_event,'enabled',p_enabled,'template',t.id));
end $$;

-- Every distinct greeting receives a menu. Source-message IDs still deduplicate webhook retries.

create or replace function public.dispatch_whatsapp_guest_replies(p_limit integer default 50,p_portal_origin text default null)returns integer
language plpgsql security definer set search_path=''as $$
declare job record;n integer:=0;cfg integer;action text;
begin
 for job in select j.*,m.conversation_id from private.whatsapp_guest_inbound_jobs j join public.messages m on m.id=j.message_id join public.whatsapp_journey_settings s on s.property_id=m.property_id and s.enabled where j.state='pending'order by j.created_at,j.message_id limit greatest(1,least(100,p_limit))for update of j skip locked loop
  -- Existing custom category navigation/template replies stay with the published menu dispatcher.
  if job.command like 'guest:v:%'or job.command~'^(10|[1-9])$'then continue;end if;
  update private.whatsapp_guest_inbound_jobs set state='done'where message_id=job.message_id;
  if job.command not like 'journey:%'and job.command not in('hi','hello','hey','menu','start','checkin','check in','check-in','checkout','check out','check-out','documents','food','services','stay','bill','preferences','reception','human','agent')and exists(select 1 from public.messages where conversation_id=job.conversation_id and journey_purpose in('menu','preferences')and created_at>now()-interval '30 seconds'and status<>'failed')then continue;end if;
  begin n:=n+private.handle_whatsapp_journey(job.conversation_id,job.message_id,job.command,p_portal_origin);
  exception when sqlstate '22023'then
   update private.whatsapp_guest_inbound_jobs set last_error=left(sqlerrm,500)where message_id=job.message_id;
   perform private.queue_journey_reply(job.conversation_id,job.message_id,'needs_attention',left(sqlerrm,500)||' Send Hi for the latest options, or reception for assistance.',null);
  end;
 end loop;
 return n+public.dispatch_whatsapp_guest_replies_before_journey(p_limit,p_portal_origin);
end $$;

create or replace function public.dispatch_whatsapp_guest_replies_before_journey(p_limit integer default 50,p_portal_origin text default null)returns integer
language plpgsql security definer set search_path=''as $$
declare job record;c public.conversations;cfg public.whatsapp_guest_menu;action text;sent int:=0;mid uuid;
begin
 update private.whatsapp_guest_runtime set portal_origin=case when private.whatsapp_public_link(p_portal_origin)and p_portal_origin!~'[?#]'and p_portal_origin!~'/s/'then p_portal_origin else null end where singleton;
 for job in select j.*,m.conversation_id from private.whatsapp_guest_inbound_jobs j join public.messages m on m.id=j.message_id where j.state='pending'order by j.created_at limit greatest(1,least(100,p_limit))for update of j skip locked loop
  update private.whatsapp_guest_inbound_jobs set state='done'where message_id=job.message_id;
  select *into c from public.conversations where id=job.conversation_id for update;
  select *into cfg from public.whatsapp_guest_menu where property_id=c.property_id;
  if not coalesce(cfg.enabled,false)or c.human_handoff or c.status<>'open'or private.is_opted_out(c.property_id,c.wa_contact_id)or c.last_inbound_at<now()-interval '24 hours'or not private.tenant_is_active(c.tenant_id)then continue;end if;
  action:=case when job.command in('hi','hello','hey','menu','start')then'menu'when job.command in('reception','human','agent')then'reception'when job.command in('location','photos','review','website')then job.command when job.command~'^guest:(stay|documents|food|services|checkin|checkout|location|photos|review|website|reception)$'then split_part(job.command,':',2)else null end;
  if cfg.data?'categories'and job.command like 'guest:v:%'then action:=private.decode_grouped_action(job.command,cfg.version);end if;
  if cfg.data?'categories'and job.command~'^(10|[1-9])$'then
   select private.decode_grouped_action(outbound_payload#>>array['interactive','action','sections','0','rows',(job.command::int-1)::text,'id'],cfg.version)into action from public.messages where conversation_id=c.id and outbound_payload#>>'{interactive,type}'='list'and status in('sent','delivered','read')and guest_menu_version=cfg.version order by created_at desc,id desc limit 1;
  end if;
  if not(cfg.data?'categories')and action is null and job.command~'^(10|[1-9])$'and exists(select 1 from public.messages where conversation_id=c.id and guest_menu_action='menu'and guest_menu_version=cfg.version and status in('sent','delivered','read')and created_at>now()-interval '24 hours')then
   select i->>'action'into action from jsonb_array_elements(cfg.data->'items')i where i->>'enabled'='true'offset(job.command::int-1)limit 1;
  end if;
  if action is null then continue;end if;
  if not(cfg.data?'categories')and action<>'menu'and not exists(select 1 from jsonb_array_elements(cfg.data->'items')where value->>'action'=action and value->>'enabled'='true')then continue;end if;
  begin
   mid:=private.queue_whatsapp_guest_reply(c.id,null,action,true,job.message_id,p_portal_origin);if mid is not null then sent:=sent+1;end if;
  exception when sqlstate '22023'then null;end;
 end loop;
 return sent;
end $$;

-- Published services deliver the owner's assigned template, including private task links.
-- Native check-in/out confirmations follow that template and keep their existing admission guards.
create or replace function private.queue_whatsapp_guest_reply(p_conversation uuid,p_request uuid,p_action text,p_automatic boolean,p_source uuid,p_origin text)returns uuid
language plpgsql security definer set search_path=''as $$
declare action text:=p_action;mid uuid;
begin
 if p_action~'^service:[a-f0-9-]{36}$'then
  mid:=private.queue_whatsapp_guest_reply_before_journey(p_conversation,p_request,p_action,p_automatic,p_source,p_origin);
  if mid is not null and p_automatic then
   select x->>'action'into action from public.whatsapp_guest_menu cfg cross join lateral jsonb_array_elements(cfg.data->'categories')k cross join lateral jsonb_array_elements(k->'services')x where cfg.property_id=(select property_id from public.conversations where id=p_conversation)and cfg.enabled and k->>'enabled'='true'and x->>'enabled'='true'and x->>'id'=split_part(p_action,':',2);
   if action in('checkin','checkout')then perform private.handle_whatsapp_journey(p_conversation,p_source,action,p_origin);end if;
  end if;
  return mid;
 end if;
 if p_automatic and p_action in('stay','checkin','checkout','services','food','documents')and exists(select 1 from public.whatsapp_journey_settings s join public.conversations c on c.property_id=s.property_id where c.id=p_conversation and s.enabled)then
  perform private.handle_whatsapp_journey(p_conversation,p_source,p_action,p_origin);
  select id into mid from public.messages where conversation_id=p_conversation and guest_reply_to=p_source order by created_at desc,id desc limit 1;return mid;
 end if;
 return private.queue_whatsapp_guest_reply_before_journey(p_conversation,p_request,p_action,p_automatic,p_source,p_origin);
end $$;

-- Inbox attachments are private, conversation-bound and rebuilt as JPEG by the hotel app.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('whatsapp-inbox-photos','whatsapp-inbox-photos',false,4194304,array['image/jpeg'])on conflict(id)do nothing;
create table public.inbox_photo_uploads(
 id uuid primary key default gen_random_uuid(),property_id uuid not null references public.properties(id),
 conversation_id uuid not null references public.conversations(id),request_id uuid not null,
 uploaded_by uuid not null references auth.users(id),storage_path text not null unique,
 digest text not null check(digest~'^[a-f0-9]{64}$'),delivery_url text not null,
 expires_at timestamptz not null,created_at timestamptz not null default now(),
 unique(conversation_id,request_id),
 check(storage_path=property_id::text||'/'||conversation_id::text||'/'||request_id::text||'.jpg')
);
alter table public.inbox_photo_uploads enable row level security;
revoke all on public.inbox_photo_uploads from anon,authenticated;
grant select on public.inbox_photo_uploads to authenticated;
grant all on public.inbox_photo_uploads to service_role;
create policy inbox_photo_read on public.inbox_photo_uploads for select to authenticated
using(private.has_permission(property_id,'whatsapp.use')and exists(select 1 from public.conversations c where c.id=conversation_id and c.property_id=inbox_photo_uploads.property_id));
alter table public.messages add column inbox_photo_id uuid references public.inbox_photo_uploads(id);

create function public.inbox_photo_context(p_property uuid,p_conversation uuid,p_request uuid)returns jsonb
language plpgsql security definer set search_path=''as $$
declare c public.conversations;m public.messages;
begin
 c:=private.lock_conversation(p_conversation,'whatsapp.use');
 if c.property_id<>p_property or p_request is null then raise exception 'Conversation not found in this hotel.'using errcode='42501';end if;
 select *into m from public.messages where conversation_id=c.id and creation_request_id=p_request;
 if m.id is null then
  perform private.staff_share(p_property);
  if c.status<>'open'or private.is_opted_out(c.property_id,c.wa_contact_id)then raise exception 'Reopen this conversation and check the guest’s messaging preference.'using errcode='22023';end if;
  if c.last_inbound_at is null or c.last_inbound_at<=now()-interval '24 hours'then raise exception 'The reply window is closed. Send an approved photo template instead.'using errcode='22023';end if;
  if not exists(select 1 from public.whatsapp_connections where id=c.connection_id and status='active')then raise exception 'Connect this hotel’s WhatsApp number first.'using errcode='22023';end if;
 end if;
 return jsonb_build_object('message_id',m.id,'photo',(select to_jsonb(a)from public.inbox_photo_uploads a where a.conversation_id=c.id and a.request_id=p_request and a.uploaded_by=auth.uid()));
end $$;

create function public.inbox_send_photo(p_property uuid,p_conversation uuid,p_request uuid,p_photo uuid,p_caption text default '')returns uuid
language plpgsql security definer set search_path=''as $$
declare c public.conversations;a public.inbox_photo_uploads;m public.messages;sender text;
begin
 perform public.inbox_photo_context(p_property,p_conversation,p_request);
 select *into c from public.conversations where id=p_conversation;
 select *into a from public.inbox_photo_uploads where id=p_photo and property_id=c.property_id and conversation_id=c.id and request_id=p_request and uploaded_by=auth.uid();
 if a.id is null or length(coalesce(p_caption,''))>1024 then raise exception 'Choose a photo and a caption up to 1,024 characters.'using errcode='22023';end if;
 select *into m from public.messages where conversation_id=c.id and creation_request_id=p_request;
 if m.id is not null then
  if m.inbox_photo_id is distinct from a.id or coalesce(m.body,'')<>trim(coalesce(p_caption,''))then raise exception 'This reply was already queued with different content. Refresh before sending another.'using errcode='22023';end if;
  return m.id;
 end if;
 if a.expires_at<now()+interval '1 hour'then raise exception 'Photo upload expired. Attach it again.'using errcode='22023';end if;
 select phone_number_id into sender from public.whatsapp_connections where id=c.connection_id;
 insert into public.messages(tenant_id,property_id,conversation_id,direction,type,body,status,sent_by,creation_request_id,inbox_photo_id,guest_sender_id,outbound_payload)
 values(c.tenant_id,c.property_id,c.id,'out','image',trim(coalesce(p_caption,'')),'queued',auth.uid(),p_request,a.id,sender,
 jsonb_build_object('type','image','image',jsonb_build_object('link',a.delivery_url,'caption',trim(coalesce(p_caption,'')))))returning *into m;
 update public.conversations set last_message_at=now()where id=c.id;
 return m.id;
end $$;
revoke all on function public.inbox_photo_context(uuid,uuid,uuid),public.inbox_send_photo(uuid,uuid,uuid,uuid,text)from public,anon;
grant execute on function public.inbox_photo_context(uuid,uuid,uuid),public.inbox_send_photo(uuid,uuid,uuid,uuid,text)to authenticated;

-- Recheck the window, opt-out, property, sender and attachment at delivery and retry time.
alter function private.inbox_delivery_error(uuid)rename to inbox_delivery_error_before_inbox_photo;
revoke all on function private.inbox_delivery_error_before_inbox_photo(uuid)from public,anon,authenticated,service_role;
create function private.inbox_delivery_error(p_message uuid)returns text
language plpgsql stable security definer set search_path=''as $$
declare m public.messages;c public.conversations;a public.inbox_photo_uploads;why text;
begin
 select *into m from public.messages where id=p_message;
 if m.inbox_photo_id is null then return private.inbox_delivery_error_before_inbox_photo(p_message);end if;
 if m.guest_identity_reset_at is not null then return 'Guest WhatsApp link was reset. Verify the guest before sending.';end if;
 why:=private.inbox_delivery_error_before_concierge(p_message);if why is not null then return why;end if;
 select *into c from public.conversations where id=m.conversation_id;
 if not private.tenant_is_active(m.tenant_id)or exists(select 1 from public.properties where id=m.property_id and archived_at is not null)then return 'Hotel messaging is paused.';end if;
 if c.status<>'open'or c.last_inbound_at is null or c.last_inbound_at<=now()-interval '24 hours'then return 'Photo reply window closed. Use an approved photo template.';end if;
 if not exists(select 1 from public.whatsapp_connections where id=c.connection_id and property_id=m.property_id and phone_number_id=m.guest_sender_id and status='active')then return 'Hotel sender changed or disconnected.';end if;
 select *into a from public.inbox_photo_uploads where id=m.inbox_photo_id and property_id=m.property_id and conversation_id=c.id and request_id=m.creation_request_id and uploaded_by=m.sent_by;
 if a.id is null or a.expires_at<=now()or m.type<>'image'or m.outbound_payload->>'type'<>'image'or m.outbound_payload#>>'{image,link}'is distinct from a.delivery_url or m.outbound_payload#>>'{image,caption}'is distinct from m.body then return 'Photo is expired or changed. Attach it again.';end if;
 return null;
end $$;
revoke all on function private.inbox_delivery_error(uuid)from public,anon,authenticated,service_role;
alter function public.inbox_retry(uuid)rename to inbox_retry_before_inbox_photo;
revoke all on function public.inbox_retry_before_inbox_photo(uuid)from public,anon,authenticated,service_role;
create function public.inbox_retry(p_message uuid)returns void
language plpgsql security definer set search_path=''as $$
declare why text;
begin
 if not exists(select 1 from public.messages where id=p_message and private.has_permission(property_id,'whatsapp.use'))then raise exception 'Not permitted.'using errcode='42501';end if;
 if exists(select 1 from public.messages where id=p_message and inbox_photo_id is not null)then
  why:=private.inbox_delivery_error(p_message);if why is not null then raise exception '%',why using errcode='22023';end if;
 end if;
 perform public.inbox_retry_before_inbox_photo(p_message);
end $$;
revoke all on function public.inbox_retry(uuid)from public,anon;
grant execute on function public.inbox_retry(uuid)to authenticated;
