-- Released checkout holds remain usable as message history, never as sellable inventory locks.
create function private.whatsapp_reservation_room_name(p_reservation uuid)returns text
language sql stable security definer set search_path=''as $$
 select string_agg(u.name,', 'order by u.name)
 from public.reservations r join public.unit_holds h on h.reservation_id=r.id and h.kind='reservation'
 join public.accommodation_units u on u.id=h.unit_id
 where r.id=p_reservation and(h.active or(r.status='checked_out'
 and not exists(select 1 from public.unit_holds a where a.reservation_id=r.id and a.kind='reservation'and a.active)
 and h.created_at=(select max(a.created_at)from public.unit_holds a where a.reservation_id=r.id and a.kind='reservation')))
$$;
revoke all on function private.whatsapp_reservation_room_name(uuid)from public,anon,authenticated,service_role;

create or replace function private.capture_whatsapp_event(p_property uuid,p_reservation uuid,p_event text,p_dedup text,p_table text,p_source uuid,p_status text,p_details jsonb default '{}',p_due timestamptz default null,p_expires timestamptz default null)returns void
language plpgsql security definer set search_path=''as $$
declare r public.reservations;rule public.whatsapp_automation_rules;g public.guests;p public.properties;payload jsonb;due timestamptz;
begin
 select *into rule from public.whatsapp_automation_rules where property_id=p_property and event_key=p_event and enabled;
 if rule.id is null then return;end if;
 select *into r from public.reservations where id=p_reservation and property_id=p_property;if r.id is null then return;end if;
 select *into g from public.guests where id=r.guest_id;select *into p from public.properties where id=p_property;
 due:=coalesce(p_due,now()+make_interval(mins=>rule.delay_minutes));
 payload:=jsonb_build_object('guest_name',g.full_name,'hotel_name',p.name,'booking_reference',upper(left(replace(r.id::text,'-',''),8)),'check_in',r.check_in::text,'check_out',r.check_out::text,'hotel_phone',p.contact_phone,'currency',trim(r.currency),'amount',r.total_amount::text,'room_name',coalesce(private.whatsapp_reservation_room_name(r.id),''),'event_label',(select x->>'label'from jsonb_array_elements(public.whatsapp_automation_catalog())x where x->>'key'=p_event))||p_details;
 insert into public.whatsapp_automation_events(property_id,tenant_id,reservation_id,guest_id,event_key,dedup_key,source_table,source_id,expected_status,rule_id,rule_version,payload,due_at,expires_at)
 values(p_property,r.tenant_id,r.id,r.guest_id,p_event,p_dedup,p_table,p_source,p_status,rule.id,rule.version,payload,due,coalesce(p_expires,due+interval '24 hours'))on conflict(property_id,event_key,dedup_key)do nothing;
end $$;

create or replace function public.dispatch_whatsapp_automations(p_limit integer default 50,p_portal_origin text default null)returns integer
language plpgsql security definer set search_path=''as $$
declare item record;e public.whatsapp_automation_events;r public.reservations;rule public.whatsapp_automation_rules;t public.message_templates;a public.whatsapp_guest_authorizations;
 due timestamptz;expires timestamptz;why text;vars jsonb;params jsonb;components jsonb;body text;k text;value text;i integer;name text;token text;mid uuid;n integer:=0;phone text;match text[];
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
  vars:=e.payload;token:=null;
  if rule.parameter_keys?'room_name'then vars:=vars||jsonb_build_object('room_name',private.whatsapp_reservation_room_name(r.id));end if;
  if e.source_table='orders'then vars:=vars||jsonb_build_object('amount',(select total::text from public.orders where id=e.source_id));end if;
  if rule.parameter_keys?'review_url'then vars:=vars||jsonb_build_object('review_url',(select data->>'review_url'from public.whatsapp_guest_settings where property_id=e.property_id));end if;
  if rule.parameter_keys?'portal_url'then
   if p_portal_origin is null or not private.whatsapp_studio_url(p_portal_origin,false)or p_portal_origin~'[?#]'or r.status in('cancelled','no_show')then
    update public.whatsapp_automation_events set state='blocked',reason='Secure guest portal origin not configured.',next_check_at=now()+interval '1 minute'where id=e.id;continue;
   end if;
   token:=encode(extensions.gen_random_bytes(32),'hex');
   insert into public.guest_access_tokens(tenant_id,property_id,reservation_id,token_hash,expires_at)values(e.tenant_id,e.property_id,r.id,encode(sha256(convert_to(token,'utf8')),'hex'),now()+interval '7 days');
   vars:=vars||jsonb_build_object('portal_url',rtrim(p_portal_origin,'/')||'/s/'||token);
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
  select wc.phone_number_id into phone from public.conversations cv join public.whatsapp_connections wc on wc.id=cv.connection_id where cv.id=a.conversation_id;
  insert into public.messages(tenant_id,property_id,conversation_id,direction,type,body,template_id,status,automation_event_id,template_components)
  values(e.tenant_id,e.property_id,a.conversation_id,'out','template',body,t.id,'queued',e.id,components)on conflict(automation_event_id)where automation_event_id is not null do nothing returning id into mid;
  if mid is null then select id into mid from public.messages where automation_event_id=e.id;end if;
  update public.whatsapp_automation_events set state='queued',reason=null,message_id=mid,sender_phone_id=phone where id=e.id;
  update public.conversations set last_message_at=now()where id=a.conversation_id;n:=n+1;
 end loop;
 return n;
end $$;
