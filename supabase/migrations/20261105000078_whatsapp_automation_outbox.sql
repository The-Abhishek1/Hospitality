-- Durable guest-facing event notifications. Disabled until a hotel explicitly enables rules.
alter table public.whatsapp_connections add column templates_sync_after timestamptz not null default now();
alter table public.message_templates add column automation_supported boolean not null default false,
 add column provider_template_id text,add column provider_waba_id text,add column provider_status text,
 add column provider_definition jsonb,add column provider_fingerprint text,add column provider_checked_at timestamptz,
 add column parameter_names jsonb not null default '[]';

create function public.whatsapp_automation_catalog()returns jsonb language sql immutable set search_path=''as $$
 select jsonb_agg(jsonb_build_object('key',key,'label',label,'group',grp,'scheduled',scheduled))from(values
 ('booking_confirmed','Booking confirmed','Reservations',false),('booking_changed','Stay dates or room updated','Reservations',false),
 ('booking_cancelled','Booking cancelled','Reservations',false),('checked_in','Check-in confirmed','Stay',false),('checked_out','Checkout confirmed','Stay',false),
 ('arrival_reminder','Pre-arrival reminder','Stay',true),('checkout_reminder','Checkout reminder','Stay',true),('review_request','Post-stay review request (marketing permission required)','Stay',true),
 ('order_placed','Food order received','Dining',false),('order_preparing','Kitchen preparing order','Dining',false),('order_ready','Food order ready','Dining',false),('order_served','Food order served','Dining',false),('order_cancelled','Food order cancelled','Dining',false),
 ('request_received','Guest request received','Services',false),('request_started','Guest request in progress','Services',false),('request_completed','Guest request or linked service task completed','Services',false),('request_cancelled','Guest request cancelled','Services',false),
 ('payment_received','Payment recorded','Billing',false),('payment_refunded','Refund recorded','Billing',false),('invoice_issued','Invoice issued','Billing',false),
 ('documents_received','Document upload received','Arrival',false),('documents_approved','Document review approved','Arrival',false),('documents_rejected','Document review needs attention','Arrival',false)
 )as e(key,label,grp,scheduled)
$$;
revoke all on function public.whatsapp_automation_catalog()from public,anon;
grant execute on function public.whatsapp_automation_catalog()to authenticated,service_role;

create table public.whatsapp_automation_rules(
 id uuid primary key default gen_random_uuid(),property_id uuid not null,tenant_id uuid not null,event_key text not null,
 enabled boolean not null default false,template_id uuid references public.message_templates(id)on delete set null,
 template_fingerprint text,parameter_keys jsonb not null default '[]',delay_minutes integer not null default 0 check(delay_minutes between 0 and 10080),
 version integer not null default 1,updated_at timestamptz not null default now(),updated_by uuid,
 unique(property_id,event_key),foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade
);
create table public.whatsapp_guest_authorizations(
 id uuid primary key default gen_random_uuid(),property_id uuid not null,tenant_id uuid not null,guest_id uuid not null,
 wa_contact_id text not null,conversation_id uuid not null,status text not null check(status in('granted','revoked')),
 evidence text not null,version integer not null default 1,updated_at timestamptz not null default now(),updated_by uuid,
 unique(property_id,guest_id),unique(property_id,wa_contact_id),
 foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade,
 foreign key(guest_id,tenant_id)references public.guests(id,tenant_id),
 foreign key(conversation_id,property_id)references public.conversations(id,property_id)
);
create table public.whatsapp_automation_events(
 id uuid primary key default gen_random_uuid(),property_id uuid not null,tenant_id uuid not null,reservation_id uuid not null,guest_id uuid not null,
 event_key text not null,dedup_key text not null,source_table text not null,source_id uuid not null,expected_status text,
 rule_id uuid not null references public.whatsapp_automation_rules(id),rule_version integer not null,
 payload jsonb not null,due_at timestamptz not null,expires_at timestamptz not null,
 state text not null default 'pending'check(state in('pending','blocked','queued','skipped')),reason text,
 next_check_at timestamptz not null default now(),message_id uuid references public.messages(id)on delete set null,
 sender_phone_id text,created_at timestamptz not null default now(),
 unique(property_id,event_key,dedup_key),foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade,
 foreign key(reservation_id,property_id)references public.reservations(id,property_id)on delete cascade
);
alter table public.messages add column automation_event_id uuid references public.whatsapp_automation_events(id)on delete cascade,
 add column template_components jsonb;
create unique index message_automation_once on public.messages(automation_event_id)where automation_event_id is not null;
create index automation_due on public.whatsapp_automation_events(next_check_at,due_at)where state in('pending','blocked');
create table public.whatsapp_automation_audit(
 id uuid primary key default gen_random_uuid(),property_id uuid not null,tenant_id uuid not null,actor uuid,
 action text not null,details jsonb not null,created_at timestamptz not null default now(),
 foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade
);
do $$declare tab text;begin
 foreach tab in array array['whatsapp_automation_rules','whatsapp_guest_authorizations','whatsapp_automation_events','whatsapp_automation_audit']loop
 execute format('alter table public.%I enable row level security',tab);
 execute format('create policy automation_read on public.%I for select to authenticated using(private.has_permission(property_id,''staff.manage''))',tab);
 end loop;
end $$;

create function public.sync_whatsapp_provider_templates(p_connection uuid,p_waba text,p_templates jsonb)returns integer
language plpgsql security definer set search_path=''as $$
declare c public.whatsapp_connections;t jsonb;n integer:=0;approved boolean;
begin
 select *into c from public.whatsapp_connections where id=p_connection and status='active'for update;
 if c.id is null or c.waba_id<>p_waba or jsonb_typeof(p_templates)<>'array'or pg_column_size(p_templates)>2000000 then raise exception 'Invalid template sync'using errcode='22023';end if;
 update public.message_templates set status='rejected',automation_supported=false,campaign_supported=false,provider_status='MISSING',provider_checked_at=now()where property_id=c.property_id and provider_template_id is not null;
 for t in select *from jsonb_array_elements(p_templates)loop
  if t->>'category'not in('utility','marketing')then continue;end if;
  approved:=t->>'provider_status'='APPROVED'and(t->>'supported')::boolean;
  insert into public.message_templates(tenant_id,property_id,name,language,category,status,body,automation_supported,campaign_supported,provider_template_id,provider_waba_id,provider_status,provider_definition,provider_fingerprint,provider_checked_at,parameter_names)
  values(c.tenant_id,c.property_id,t->>'name',t->>'language',t->>'category',case when approved then'approved'else'pending'end,t->>'body',approved,approved and t->>'category'='marketing'and jsonb_array_length(t->'parameter_names')=0,t->>'provider_id',p_waba,t->>'provider_status',t->'definition',encode(sha256(convert_to((t->'definition')::text,'utf8')),'hex'),now(),t->'parameter_names')
  on conflict(property_id,name,language)do update set category=excluded.category,status=excluded.status,body=excluded.body,automation_supported=excluded.automation_supported,campaign_supported=excluded.campaign_supported,provider_template_id=excluded.provider_template_id,provider_waba_id=excluded.provider_waba_id,provider_status=excluded.provider_status,provider_definition=excluded.provider_definition,provider_fingerprint=excluded.provider_fingerprint,provider_checked_at=excluded.provider_checked_at,parameter_names=excluded.parameter_names;
  n:=n+1;
 end loop;
 update public.whatsapp_connections set templates_sync_after=now()+interval '15 minutes'where id=c.id;
 return n;
end $$;

create function public.save_whatsapp_automation_rule(p_property uuid,p_event text,p_version integer,p_enabled boolean,p_template uuid,p_keys jsonb,p_delay integer)returns void
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
 end loop;
 insert into public.whatsapp_automation_rules(property_id,tenant_id,event_key,enabled,template_id,template_fingerprint,parameter_keys,delay_minutes,updated_by)
 values(p_property,tenant,p_event,p_enabled,t.id,t.provider_fingerprint,p_keys,p_delay,auth.uid())
 on conflict(property_id,event_key)do update set enabled=excluded.enabled,template_id=excluded.template_id,template_fingerprint=excluded.template_fingerprint,parameter_keys=excluded.parameter_keys,delay_minutes=excluded.delay_minutes,updated_by=auth.uid(),updated_at=now(),version=whatsapp_automation_rules.version+1;
 insert into public.whatsapp_automation_audit(property_id,tenant_id,actor,action,details)values(p_property,tenant,auth.uid(),'rule_saved',jsonb_build_object('event',p_event,'enabled',p_enabled,'template',t.id));
end $$;

create function public.authorize_whatsapp_stay_updates(p_property uuid,p_reservation uuid,p_version integer,p_status text,p_evidence text,p_confirmed boolean)returns void
language plpgsql security definer set search_path=''as $$
declare r public.reservations;g public.guests;a public.whatsapp_guest_authorizations;w public.whatsapp_connections;phone text;cv uuid;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel administrator access required'using errcode='42501';end if;
 perform 1 from public.properties where id=p_property for update;
 select *into r from public.reservations where id=p_reservation and property_id=p_property;
 if r.id is null or p_status not in('granted','revoked')or p_confirmed is not true or length(trim(coalesce(p_evidence,'')))not between 10 and 1000 then raise exception 'Select a stay and record the guest’s confirmed number and permission evidence.'using errcode='22023';end if;
 select *into g from public.guests where id=r.guest_id and tenant_id=r.tenant_id;
 select *into a from public.whatsapp_guest_authorizations where property_id=p_property and guest_id=g.id;
 if coalesce(a.version,0)<>p_version then raise exception 'Permission changed. Refresh before saving.'using errcode='40001';end if;
 if p_status='revoked'and a.id is not null then
  update public.whatsapp_guest_authorizations set status='revoked',evidence=trim(p_evidence),version=version+1,updated_at=now(),updated_by=auth.uid()where id=a.id;
 else
  phone:=private.campaign_phone(g.phone);select *into w from public.whatsapp_connections where property_id=p_property and status='active';
  if phone is null or w.id is null then raise exception 'An active hotel sender and a guest phone with country code are required.'using errcode='22023';end if;
  insert into public.conversations(tenant_id,property_id,connection_id,wa_contact_id,contact_name,guest_id)values(r.tenant_id,p_property,w.id,phone,g.full_name,g.id)
  on conflict(connection_id,wa_contact_id)do nothing returning id into cv;
  if cv is null then select id into cv from public.conversations where connection_id=w.id and wa_contact_id=phone and(guest_id is null or guest_id=g.id);end if;
  if cv is null then raise exception 'This contact is linked to another guest. Review the guest identity first.'using errcode='22023';end if;
  update public.conversations set guest_id=g.id where id=cv;
  insert into public.whatsapp_guest_authorizations(property_id,tenant_id,guest_id,wa_contact_id,conversation_id,status,evidence,updated_by)
  values(p_property,r.tenant_id,g.id,phone,cv,p_status,trim(p_evidence),auth.uid())on conflict(property_id,guest_id)do update set wa_contact_id=excluded.wa_contact_id,conversation_id=excluded.conversation_id,status=excluded.status,evidence=excluded.evidence,version=whatsapp_guest_authorizations.version+1,updated_at=now(),updated_by=auth.uid();
 end if;
 insert into public.whatsapp_automation_audit(property_id,tenant_id,actor,action,details)values(p_property,r.tenant_id,auth.uid(),'stay_permission',jsonb_build_object('guest',g.id,'status',p_status,'evidence',trim(p_evidence)));
end $$;

create function private.capture_whatsapp_event(p_property uuid,p_reservation uuid,p_event text,p_dedup text,p_table text,p_source uuid,p_status text,p_details jsonb default '{}',p_due timestamptz default null,p_expires timestamptz default null)returns void
language plpgsql security definer set search_path=''as $$
declare r public.reservations;rule public.whatsapp_automation_rules;g public.guests;p public.properties;payload jsonb;due timestamptz;
begin
 select *into rule from public.whatsapp_automation_rules where property_id=p_property and event_key=p_event and enabled;
 if rule.id is null then return;end if;
 select *into r from public.reservations where id=p_reservation and property_id=p_property;if r.id is null then return;end if;
 select *into g from public.guests where id=r.guest_id;select *into p from public.properties where id=p_property;
 due:=coalesce(p_due,now()+make_interval(mins=>rule.delay_minutes));
 payload:=jsonb_build_object('guest_name',g.full_name,'hotel_name',p.name,'booking_reference',upper(left(replace(r.id::text,'-',''),8)),'check_in',r.check_in::text,'check_out',r.check_out::text,'hotel_phone',p.contact_phone,'currency',trim(r.currency),'amount',r.total_amount::text,'room_name',coalesce((select string_agg(u.name,', 'order by u.name)from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.reservation_id=r.id and h.kind='reservation'and h.active),''),'event_label',(select x->>'label'from jsonb_array_elements(public.whatsapp_automation_catalog())x where x->>'key'=p_event))||p_details;
 insert into public.whatsapp_automation_events(property_id,tenant_id,reservation_id,guest_id,event_key,dedup_key,source_table,source_id,expected_status,rule_id,rule_version,payload,due_at,expires_at)
 values(p_property,r.tenant_id,r.id,r.guest_id,p_event,p_dedup,p_table,p_source,p_status,rule.id,rule.version,payload,due,coalesce(p_expires,due+interval '24 hours'))on conflict(property_id,event_key,dedup_key)do nothing;
end $$;

create function private.whatsapp_domain_event()returns trigger language plpgsql security definer set search_path=''as $$
declare d jsonb:=to_jsonb(new);prev jsonb;ev text;rid uuid;details jsonb:='{}';dedup text;related public.guest_requests;pid uuid:=(d->>'property_id')::uuid;sid uuid:=(d->>'id')::uuid;st text:=d->>'status';
begin
 if tg_op='UPDATE'then prev:=to_jsonb(old);end if;
 if tg_table_name='reservations'then
  rid:=sid;
  if tg_op='INSERT'then if st='confirmed'then ev:='booking_confirmed';end if;
  elsif st is distinct from prev->>'status'then ev:=case st when'confirmed'then'booking_confirmed'when'checked_in'then'checked_in'when'checked_out'then'checked_out'when'cancelled'then'booking_cancelled'end;
  elsif(d->>'check_in',d->>'check_out')is distinct from(prev->>'check_in',prev->>'check_out')then ev:='booking_changed';end if;
 elsif tg_table_name='unit_holds'then
  if d->>'kind'='reservation'and(d->>'reservation_id')is not null and(tg_op='INSERT'or d->>'unit_id'is distinct from prev->>'unit_id')and exists(select 1 from public.reservations where id=(d->>'reservation_id')::uuid and created_at<now())then rid:=(d->>'reservation_id')::uuid;ev:='booking_changed';st:='active';end if;
 elsif tg_table_name='orders'then
  rid:=(d->>'reservation_id')::uuid;
  if tg_op='INSERT'or st is distinct from prev->>'status'then ev:=case st when'placed'then'order_placed'when'preparing'then'order_preparing'when'ready'then'order_ready'when'served'then'order_served'when'cancelled'then'order_cancelled'end;end if;
  details:=jsonb_build_object('order_reference',upper(left(replace(sid::text,'-',''),8)));
 elsif tg_table_name='guest_requests'then
  rid:=(d->>'reservation_id')::uuid;
  if tg_op='INSERT'or st is distinct from prev->>'status'then ev:=case st when'new'then'request_received'when'in_progress'then'request_started'when'completed'then'request_completed'when'cancelled'then'request_cancelled'end;end if;
  details:=jsonb_build_object('request_title',d->>'title');
  if ev='request_completed'then dedup:='request:'||sid::text||':completed';end if;
 elsif tg_table_name='tasks'then
  if tg_op='UPDATE'and st='done'and st is distinct from prev->>'status'and d->>'guest_request_id'is not null then
   select *into related from public.guest_requests where id=(d->>'guest_request_id')::uuid and property_id=pid;
   rid:=related.reservation_id;ev:='request_completed';dedup:='request:'||related.id::text||':completed';details:=jsonb_build_object('request_title',related.title);
  end if;
 elsif tg_table_name='payments'then
  select reservation_id into rid from public.folios where id=(d->>'folio_id')::uuid and property_id=pid;
  if rid is null then select reservation_id into rid from public.orders where id=(d->>'order_id')::uuid and property_id=pid;end if;
  ev:='payment_received';details:=jsonb_build_object('amount',d->>'amount');
 elsif tg_table_name='refunds'then
  select coalesce(f.reservation_id,o.reservation_id)into rid from public.payments pay left join public.folios f on f.id=pay.folio_id left join public.orders o on o.id=pay.order_id where pay.id=(d->>'payment_id')::uuid and pay.property_id=pid;
  ev:='payment_refunded';details:=jsonb_build_object('amount',d->>'amount');
 elsif tg_table_name='invoices'then
  select reservation_id into rid from public.folios where id=(d->>'folio_id')::uuid and property_id=pid;
  ev:='invoice_issued';details:=jsonb_build_object('invoice_number',d->>'number','amount',d->>'total');
 elsif tg_table_name='guest_documents'then
  rid:=(d->>'reservation_id')::uuid;
  if tg_op='UPDATE'and st is distinct from prev->>'status'then ev:=case st when'uploaded'then'documents_received'when'approved'then'documents_approved'when'rejected'then'documents_rejected'end;end if;
 end if;
 if ev is not null and rid is not null then
  -- Stable per-object milestones; modifications deduplicate within a transaction.
  dedup:=coalesce(dedup,case when ev='booking_changed'then'stay:'||rid::text||':changed:'||txid_current()::text else tg_table_name||':'||sid::text||':'||ev end);
  perform private.capture_whatsapp_event(pid,rid,ev,dedup,tg_table_name,sid,st,details);
 end if;
 return new;
end $$;
do $$declare tab text;begin
 foreach tab in array array['reservations','unit_holds','orders','guest_requests','tasks','guest_documents']loop
 execute format('create trigger whatsapp_domain_event after insert or update on public.%I for each row execute function private.whatsapp_domain_event()',tab);
 end loop;
 foreach tab in array array['payments','refunds','invoices']loop
 execute format('create trigger whatsapp_domain_event after insert on public.%I for each row execute function private.whatsapp_domain_event()',tab);
 end loop;
end $$;

revoke all on function private.capture_whatsapp_event(uuid,uuid,text,text,text,uuid,text,jsonb,timestamptz,timestamptz),private.whatsapp_domain_event()from public,anon,authenticated;
revoke all on function public.sync_whatsapp_provider_templates(uuid,text,jsonb)from public,anon,authenticated;
grant execute on function public.sync_whatsapp_provider_templates(uuid,text,jsonb)to service_role;
revoke all on function public.save_whatsapp_automation_rule(uuid,text,integer,boolean,uuid,jsonb,integer),public.authorize_whatsapp_stay_updates(uuid,uuid,integer,text,text,boolean)from public,anon;
grant execute on function public.save_whatsapp_automation_rule(uuid,text,integer,boolean,uuid,jsonb,integer),public.authorize_whatsapp_stay_updates(uuid,uuid,integer,text,text,boolean)to authenticated;
