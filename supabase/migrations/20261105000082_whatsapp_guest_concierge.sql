-- Live, opt-in hotel concierge. New rich replies are fenced from old queue consumers.
create table public.whatsapp_guest_menu (
 property_id uuid primary key references public.properties(id) on delete cascade,
 version integer not null default 1, enabled boolean not null default false,
 data jsonb not null, updated_at timestamptz not null default now(),updated_by uuid
);
alter table public.whatsapp_guest_menu enable row level security;
create policy guest_menu_read on public.whatsapp_guest_menu for select to authenticated using(private.has_permission(property_id,'staff.manage'));
revoke all on public.whatsapp_guest_menu from anon,authenticated;
grant select on public.whatsapp_guest_menu to authenticated;grant all on public.whatsapp_guest_menu to service_role;
create table private.whatsapp_guest_inbound_jobs (
 message_id uuid primary key references public.messages(id) on delete cascade,
 command text not null,state text not null default 'pending',created_at timestamptz not null default clock_timestamp()
);
create index on private.whatsapp_guest_inbound_jobs(created_at)where state='pending';
alter table public.messages add column outbound_payload jsonb,add column guest_menu_version integer,
 add column guest_menu_action text,add column guest_menu_automatic boolean not null default false,
 add column guest_reply_to uuid references public.messages(id) on delete cascade,
 add column guest_stay_id uuid references public.reservations(id) on delete cascade,
 add column guest_authorization_version integer,add column guest_sender_id text;
create unique index guest_reply_dedup on public.messages(guest_reply_to,guest_menu_action)where guest_reply_to is not null;

create function private.whatsapp_public_link(value text)returns boolean language sql immutable set search_path=''as $$
 select coalesce(private.whatsapp_studio_url(value,false)and value~'^https://[a-zA-Z0-9][a-zA-Z0-9.-]+[a-zA-Z0-9]([/:?#]|$)'
 and value!~*'^https://([^/]*@|localhost([/:]|$)|[^/]*\.local([/:]|$)|127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|0\.|\[)',false)
$$;
create function public.save_whatsapp_guest_menu(p_property uuid,p_version integer,p_enabled boolean,p_data jsonb)returns void
language plpgsql security definer set search_path=''as $$
declare row public.whatsapp_guest_menu;item jsonb;key text;enabled_count int;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel administration access required.'using errcode='42501';end if;
 if p_enabled is null or p_data is null or jsonb_typeof(p_data)<>'object'or pg_column_size(p_data)>24000 then raise exception 'Check the guest menu form.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('wa-studio:'||p_property::text,0));
 perform pg_advisory_xact_lock(hashtextextended('guest-menu:'||p_property::text,0));
 select *into row from public.whatsapp_guest_menu where property_id=p_property;
 if coalesce(row.version,0)<>p_version then raise exception 'Guest menu changed. Refresh before saving.'using errcode='40001';end if;
 if jsonb_typeof(p_data->'intro')is distinct from 'string'or length(trim(p_data->>'intro'))not between 1 and 500 or jsonb_typeof(p_data->'items')is distinct from 'array'or jsonb_array_length(p_data->'items')not between 1 and 11 then raise exception 'Add a welcome message and menu options.'using errcode='22023';end if;
 if(select count(distinct value->>'action')from jsonb_array_elements(p_data->'items'))<>jsonb_array_length(p_data->'items')then raise exception 'Each menu option may appear once.'using errcode='22023';end if;
 for item in select *from jsonb_array_elements(p_data->'items')loop
  if item->>'action'is null or item->>'action'not in('stay','documents','food','services','checkin','checkout','location','photos','review','website','reception')or jsonb_typeof(item->'label')is distinct from 'string'or length(trim(item->>'label'))not between 1 and 24 or jsonb_typeof(item->'enabled')is distinct from 'boolean'then raise exception 'Use supported actions and labels up to 24 characters.'using errcode='22023';end if;
 end loop;
 select count(*)into enabled_count from jsonb_array_elements(p_data->'items')where value->>'enabled'='true';
 if enabled_count not between 1 and 10 then raise exception 'Enable between 1 and 10 menu options.'using errcode='22023';end if;
 foreach key in array array['maps_url','review_url','website_url']loop
  if p_data?key and jsonb_typeof(p_data->key)is distinct from 'string'then raise exception 'Hotel links must be text.'using errcode='22023';end if;
  if coalesce(p_data->>key,'')<>''and not private.whatsapp_public_link(p_data->>key)then raise exception 'Use public HTTPS hotel links.'using errcode='22023';end if;
 end loop;
 if jsonb_typeof(p_data->'photos')is distinct from 'array'or jsonb_array_length(p_data->'photos')>5 then raise exception 'Add up to five public hotel photos.'using errcode='22023';end if;
 for item in select *from jsonb_array_elements(p_data->'photos')loop
  if not private.whatsapp_public_link(item->>'url')or jsonb_typeof(item->'caption')is distinct from 'string'or length(item->>'caption')>1024 then raise exception 'Each hotel photo needs a public HTTPS image link and caption up to 1024 characters.'using errcode='22023';end if;
 end loop;
 if p_enabled and exists(select 1 from jsonb_array_elements(p_data->'items')i where i->>'enabled'='true'and(case i->>'action'when'location'then coalesce(p_data->>'maps_url','')=''when'review'then coalesce(p_data->>'review_url','')=''when'website'then coalesce(p_data->>'website_url','')=''when'photos'then jsonb_array_length(p_data->'photos')=0 else false end))then raise exception 'Configure the links and photos for enabled menu options.'using errcode='22023';end if;
 insert into public.whatsapp_guest_menu(property_id,enabled,data,updated_by)values(p_property,p_enabled,p_data,auth.uid())on conflict(property_id)do update set enabled=excluded.enabled,data=excluded.data,version=whatsapp_guest_menu.version+1,updated_at=now(),updated_by=auth.uid();
 insert into public.whatsapp_guest_settings(property_id,tenant_id,data)select p_property,p.tenant_id,jsonb_build_object('maps_url',coalesce(p_data->>'maps_url',''),'review_url',coalesce(p_data->>'review_url',''),'website_url',coalesce(p_data->>'website_url',''),'hotel_photo_url',coalesce(p_data#>>'{photos,0,url}',''))from public.properties p where p.id=p_property on conflict(property_id)do update set data=whatsapp_guest_settings.data||excluded.data,version=whatsapp_guest_settings.version+1,updated_at=now();
end $$;
revoke all on function public.save_whatsapp_guest_menu(uuid,integer,boolean,jsonb)from public,anon;grant execute on function public.save_whatsapp_guest_menu(uuid,integer,boolean,jsonb)to authenticated;

-- Capture only new, authenticated provider deliveries. Existing STOP processing runs first.
alter function public.ingest_whatsapp_inbound(text,text,text,text,text,text,text,jsonb,timestamptz)rename to ingest_whatsapp_inbound_before_concierge;
revoke all on function public.ingest_whatsapp_inbound_before_concierge(text,text,text,text,text,text,text,jsonb,timestamptz)from public,anon,authenticated,service_role;
create function public.ingest_whatsapp_inbound(p_phone_number_id text,p_event_key text,p_wa_contact_id text,p_contact_name text,p_wa_message_id text,p_type text,p_body text,p_payload jsonb,p_sent_at timestamptz default now())returns uuid
language plpgsql security definer set search_path=''as $$
declare cid uuid;mid uuid;command text;display text;
begin
 command:=case p_type when'interactive'then coalesce(p_payload#>>'{interactive,list_reply,id}',p_payload#>>'{interactive,button_reply,id}','')when'button'then coalesce(p_payload#>>'{button,payload}','')else coalesce(p_body,'')end;
 display:=case when p_type='interactive'then coalesce(p_payload#>>'{interactive,list_reply,title}',p_payload#>>'{interactive,button_reply,title}',p_body)when p_type='button'then coalesce(p_payload#>>'{button,text}',p_body)else p_body end;
 cid:=public.ingest_whatsapp_inbound_before_concierge(p_phone_number_id,p_event_key,p_wa_contact_id,p_contact_name,p_wa_message_id,p_type,display,p_payload,least(coalesce(p_sent_at,now()),now()));
 if cid is not null then
  select id into mid from public.messages where conversation_id=cid and wa_message_id=p_wa_message_id and direction='in';
  if mid is not null and exists(select 1 from public.whatsapp_guest_menu where property_id=(select property_id from public.conversations where id=cid)and enabled)then insert into private.whatsapp_guest_inbound_jobs(message_id,command)values(mid,left(regexp_replace(lower(trim(command)),'[.!?[:space:]]+$','','g'),200))on conflict do nothing;perform private.wake_whatsapp_guest_worker();end if;
 end if;
 return cid;
end $$;
revoke all on function public.ingest_whatsapp_inbound(text,text,text,text,text,text,text,jsonb,timestamptz)from public,anon,authenticated;grant execute on function public.ingest_whatsapp_inbound(text,text,text,text,text,text,text,jsonb,timestamptz)to service_role;

-- A phone match alone never grants a private link. Require staff-verified binding and one eligible stay.
create function private.whatsapp_verified_menu_stay(p_conversation uuid)returns uuid
language sql stable security definer set search_path=''as $$
 select case when count(*)=1 then (array_agg(r.id))[1]end
 from public.conversations c join public.whatsapp_guest_authorizations a on a.conversation_id=c.id and a.property_id=c.property_id and a.guest_id=c.guest_id and a.status='granted'and a.wa_contact_id=c.wa_contact_id
 join public.guests g on g.id=a.guest_id and private.campaign_phone(g.phone)=c.wa_contact_id
 join public.reservations r on r.guest_id=g.id and r.property_id=c.property_id
 join public.properties p on p.id=r.property_id
 where c.id=p_conversation and r.status in('confirmed','checked_in')and r.check_out>=(now()at time zone p.timezone)::date
$$;

create function private.queue_whatsapp_guest_reply(p_conversation uuid,p_request uuid,p_action text,p_automatic boolean,p_source uuid,p_origin text)returns uuid
language plpgsql security definer set search_path=''as $$
declare c public.conversations;cfg public.whatsapp_guest_menu;payload jsonb;body text;url text;token text;rid uuid;authver int;sender text;mid uuid;first_id uuid;item jsonb;rows jsonb;idx int:=0;
begin
 select *into c from public.conversations where id=p_conversation for update;
 if not found or not private.tenant_is_active(c.tenant_id)then raise exception 'Hotel account is unavailable.'using errcode='22023';end if;
 if c.status<>'open'or private.is_opted_out(c.property_id,c.wa_contact_id)or c.last_inbound_at is null or c.last_inbound_at<now()-interval '24 hours'then raise exception 'An open conversation and a current 24-hour reply window are required.'using errcode='22023';end if;
 select phone_number_id into sender from public.whatsapp_connections where id=c.connection_id and status='active';if sender is null then raise exception 'WhatsApp is disconnected.'using errcode='22023';end if;
 select *into cfg from public.whatsapp_guest_menu where property_id=c.property_id;
 if not found then raise exception 'Configure this hotel’s guest menu first.'using errcode='22023';end if;
 if p_automatic and(not cfg.enabled or c.human_handoff)then return null;end if;
 if p_action<>'menu'and not exists(select 1 from jsonb_array_elements(cfg.data->'items')where value->>'action'=p_action and value->>'enabled'='true')then raise exception 'This menu option is not enabled.'using errcode='22023';end if;
 if p_request is not null then select id into mid from public.messages where conversation_id=c.id and creation_request_id=p_request;if found then return mid;end if;end if;
 if p_action='menu'then
  select jsonb_agg(jsonb_build_object('id','guest:'||(i->>'action'),'title',i->>'label')order by n)into rows from jsonb_array_elements(cfg.data->'items')with ordinality t(i,n)where i->>'enabled'='true';
  body:=cfg.data->>'intro';payload:=jsonb_build_object('type','interactive','interactive',jsonb_build_object('type','list','body',jsonb_build_object('text',body),'action',jsonb_build_object('button','Choose a service','sections',jsonb_build_array(jsonb_build_object('title','Hotel services','rows',rows)))));
 elsif p_action in('stay','documents','food','services','checkin','checkout')then
  rid:=private.whatsapp_verified_menu_stay(c.id);
  if rid is null then
   body:='For your privacy, reception needs to verify your stay and WhatsApp number before sharing a personal guest link. Please contact reception for help.';
   payload:=jsonb_build_object('type','text','text',jsonb_build_object('body',body));
  else
   if not private.whatsapp_public_link(p_origin)or p_origin~'[?#]'or p_origin~'/s/'then raise exception 'Secure guest portal is not configured.'using errcode='22023';end if;
   select version into authver from public.whatsapp_guest_authorizations where conversation_id=c.id and guest_id=c.guest_id and status='granted';
   token:=encode(extensions.gen_random_bytes(32),'hex');
   insert into public.guest_access_tokens(tenant_id,property_id,reservation_id,token_hash,expires_at)values(c.tenant_id,c.property_id,rid,encode(sha256(convert_to(token,'utf8')),'hex'),now()+interval '7 days');
   url:=rtrim(p_origin,'/')||'/s/'||token||case p_action when'documents'then'?view=documents'when'food'then'?view=food'when'services'then'?view=services'when'checkin'then'?intent=checkin'when'checkout'then'?intent=checkout'else''end;
   body:='Open your personal guest page to view your stay and available services. Check-in and checkout requests are subject to hotel confirmation.';
  end if;
 elsif p_action in('location','review','website')then
  url:=cfg.data->>case p_action when'location'then'maps_url'when'review'then'review_url'else'website_url'end;
  if not private.whatsapp_public_link(url)then raise exception 'Configure the hotel link first.'using errcode='22023';end if;
  body:=case p_action when'location'then'Here are the directions to our hotel.'when'review'then'You can share your hotel experience using the review link below.'else'Explore our hotel using the link below.'end;
 elsif p_action='photos'then
  if jsonb_array_length(cfg.data->'photos')=0 then raise exception 'Add hotel photos first.'using errcode='22023';end if;
 elsif p_action='reception'then
  body:='Your conversation has been handed to reception. Our team will reply here. If you need urgent help, contact the hotel directly.';
  payload:=jsonb_build_object('type','text','text',jsonb_build_object('body',body));
  update public.conversations set human_handoff=true,version=version+1 where id=c.id;
 else raise exception 'Choose a supported guest action.'using errcode='22023';end if;
 if url is not null then payload:=jsonb_build_object('type','interactive','interactive',jsonb_build_object('type','cta_url','body',jsonb_build_object('text',body),'action',jsonb_build_object('name','cta_url','parameters',jsonb_build_object('display_text',case p_action when'location'then'Get directions'when'review'then'Leave a review'when'website'then'Visit hotel website'else'Open my guest page'end,'url',url))));end if;
 for item in select value from jsonb_array_elements(case when p_action='photos'then cfg.data->'photos'else jsonb_build_array(payload)end)loop
  if p_action='photos'then body:=coalesce(nullif(item->>'caption',''),'Hotel photo');payload:=jsonb_build_object('type','image','image',jsonb_build_object('link',item->>'url','caption',body));else payload:=item;end if;
  insert into public.messages(tenant_id,property_id,conversation_id,direction,type,body,status,sent_by,creation_request_id,outbound_payload,guest_menu_version,guest_menu_action,guest_menu_automatic,guest_reply_to,guest_stay_id,guest_authorization_version,guest_sender_id)
  values(c.tenant_id,c.property_id,c.id,'out',payload->>'type',body,'queued',case when p_automatic then null else auth.uid()end,case when idx=0 then p_request else null end,payload,cfg.version,p_action||case when p_action='photos'then':'||idx else''end,p_automatic,p_source,rid,authver,sender)on conflict do nothing returning id into mid;
  first_id:=coalesce(first_id,mid);idx:=idx+1;
 end loop;
 update public.conversations set last_message_at=now()where id=c.id;
 return first_id;
end $$;

create table private.whatsapp_guest_runtime(singleton boolean primary key default true check(singleton),portal_origin text,last_wake_at timestamptz);
insert into private.whatsapp_guest_runtime(singleton)values(true);

create function private.wake_whatsapp_guest_worker()returns void language plpgsql security definer set search_path=''as $$
begin
 with available as(select singleton from private.whatsapp_guest_runtime where singleton and(last_wake_at is null or last_wake_at<clock_timestamp()-interval '5 seconds')for update skip locked)
 update private.whatsapp_guest_runtime r set last_wake_at=clock_timestamp()from available a where r.singleton=a.singleton;
 if found then
  begin perform private.invoke_whatsapp_cloud_worker();exception when others then null;end;
 end if;
end $$;
revoke all on function private.wake_whatsapp_guest_worker()from public,anon,authenticated,service_role;

create function public.inbox_guest_message(p_conversation uuid,p_request uuid,p_action text)returns uuid
language plpgsql security definer set search_path=''as $$
declare c public.conversations;mid uuid;
begin
 c:=private.lock_conversation(p_conversation,'whatsapp.use');
 if p_request is null then raise exception 'Refresh the reply form.'using errcode='22023';end if;
 -- Only the service worker can set this origin; the browser cannot supply a portal host.
 mid:=private.queue_whatsapp_guest_reply(p_conversation,p_request,p_action,false,null,(select portal_origin from private.whatsapp_guest_runtime where singleton));
 perform private.wake_whatsapp_guest_worker();return mid;
end $$;
revoke all on function public.inbox_guest_message(uuid,uuid,text)from public,anon;grant execute on function public.inbox_guest_message(uuid,uuid,text)to authenticated;

create function public.dispatch_whatsapp_guest_replies(p_limit integer default 50,p_portal_origin text default null)returns integer
language plpgsql security definer set search_path=''as $$
declare job record;c public.conversations;cfg public.whatsapp_guest_menu;action text;sent int:=0;mid uuid;
begin
 update private.whatsapp_guest_runtime set portal_origin=case when private.whatsapp_public_link(p_portal_origin)and p_portal_origin!~'[?#]'and p_portal_origin!~'/s/'then p_portal_origin else null end where singleton;
 for job in select j.*,m.conversation_id from private.whatsapp_guest_inbound_jobs j join public.messages m on m.id=j.message_id where j.state='pending'order by j.created_at limit greatest(1,least(100,p_limit))for update of j skip locked loop
  update private.whatsapp_guest_inbound_jobs set state='done'where message_id=job.message_id;
  select *into c from public.conversations where id=job.conversation_id for update;
  select *into cfg from public.whatsapp_guest_menu where property_id=c.property_id;
  if not coalesce(cfg.enabled,false)or c.human_handoff or c.status<>'open'or private.is_opted_out(c.property_id,c.wa_contact_id)or c.last_inbound_at<now()-interval '24 hours'or not private.tenant_is_active(c.tenant_id)then continue;end if;
  if job.message_id is distinct from(select j.message_id from private.whatsapp_guest_inbound_jobs j join public.messages m on m.id=j.message_id where m.conversation_id=c.id order by j.created_at desc,j.message_id desc limit 1)then continue;end if;
  action:=case when job.command in('hi','hello','hey','menu','start')then'menu'when job.command in('reception','human','agent')then'reception'when job.command in('location','photos','review','website')then job.command when job.command~'^guest:(stay|documents|food|services|checkin|checkout|location|photos|review|website|reception)$'then split_part(job.command,':',2)else null end;
  if action is null and job.command~'^(10|[1-9])$'and exists(select 1 from public.messages where conversation_id=c.id and guest_menu_action='menu'and guest_menu_version=cfg.version and status in('sent','delivered','read')and created_at>now()-interval '24 hours')then
   select i->>'action'into action from jsonb_array_elements(cfg.data->'items')i where i->>'enabled'='true'offset(job.command::int-1)limit 1;
  end if;
  if action is null then continue;end if;
  if action<>'menu'and not exists(select 1 from jsonb_array_elements(cfg.data->'items')where value->>'action'=action and value->>'enabled'='true')then continue;end if;
  -- Repeated provider events and repeated greetings within a short interval do not flood the guest.
  if action='menu'and exists(select 1 from public.messages where conversation_id=c.id and guest_menu_action='menu'and created_at>now()-interval '30 seconds'and status<>'failed')then continue;end if;
  begin
   mid:=private.queue_whatsapp_guest_reply(c.id,null,action,true,job.message_id,p_portal_origin);if mid is not null then sent:=sent+1;end if;
  exception when sqlstate '22023'then null;end;
 end loop;
 return sent;
end $$;
revoke all on function public.dispatch_whatsapp_guest_replies(integer,text)from public,anon,authenticated;grant execute on function public.dispatch_whatsapp_guest_replies(integer,text)to service_role;

alter function private.inbox_delivery_error(uuid)rename to inbox_delivery_error_before_concierge;
create function private.inbox_delivery_error(p_message uuid)returns text language plpgsql stable security definer set search_path=''as $$
declare m public.messages;c public.conversations;cfg public.whatsapp_guest_menu;why text;
begin
 why:=private.inbox_delivery_error_before_concierge(p_message);if why is not null then return why;end if;
 select *into m from public.messages where id=p_message;if m.outbound_payload is null then return null;end if;
 select *into c from public.conversations where id=m.conversation_id;
 select *into cfg from public.whatsapp_guest_menu where property_id=m.property_id;
 if c.status<>'open'or c.last_inbound_at is null or c.last_inbound_at<now()-interval '24 hours'then return 'Guest reply window closed.';end if;
 if cfg.version is distinct from m.guest_menu_version then return 'Hotel menu or links changed. Send a fresh reply.';end if;
 if m.guest_menu_automatic and(not cfg.enabled or c.human_handoff and m.guest_menu_action<>'reception')then return 'Automatic replies paused or handed to reception.';end if;
 if not exists(select 1 from public.whatsapp_connections where id=c.connection_id and phone_number_id=m.guest_sender_id and status='active')then return 'Guest reply sender changed.';end if;
 if m.guest_stay_id is not null and(m.guest_stay_id is distinct from private.whatsapp_verified_menu_stay(c.id)or not exists(select 1 from public.whatsapp_guest_authorizations where conversation_id=c.id and version=m.guest_authorization_version and status='granted'))then return 'Private guest access changed. Verify the stay again.';end if;
 return null;
end $$;
revoke all on function private.inbox_delivery_error(uuid)from public,anon,authenticated;

create or replace function public.claim_outbound_messages_v3(p_limit int default 10,p_allow_campaigns boolean default false)
returns table(message_id uuid,phone_number_id text,credentials_ref text,wa_contact_id text,msg_type text,msg_body text,template_name text,template_language text,attempt int)
language plpgsql security definer set search_path=''as $$
begin
 update public.messages set status='failed',delivery_uncertain=true,locked_at=null,error='Delivery outcome unknown after worker interruption. Check provider status before sending again.'where direction='out'and status='sending'and locked_at<now()-interval '5 minutes';
 update public.messages m set status='failed',error=private.inbox_delivery_error(m.id),locked_at=null where m.direction='out'and m.status='queued'and m.automation_event_id is null and m.outbound_payload is null and m.next_attempt_at<=now()and(m.campaign_id is null or p_allow_campaigns)and private.inbox_delivery_error(m.id)is not null;
 return query with picked as(select m.id from public.messages m where m.direction='out'and m.status='queued'and m.automation_event_id is null and m.outbound_payload is null and m.next_attempt_at<=now()and m.attempts<5 and(m.campaign_id is null or p_allow_campaigns)
 order by m.created_at,m.id limit greatest(1,least(10,p_limit))for update skip locked),
 upd as(update public.messages m set status='sending',locked_at=now(),attempts=m.attempts+1 from picked where m.id=picked.id returning m.*)
 select u.id,wc.phone_number_id,wc.credentials_ref,cv.wa_contact_id,u.type,u.body,t.name,t.language,u.attempts from upd u join public.conversations cv on cv.id=u.conversation_id join public.whatsapp_connections wc on wc.id=cv.connection_id left join public.message_templates t on t.id=u.template_id;
end $$;

create function public.claim_outbound_messages_v5(p_limit int default 10,p_allow_campaigns boolean default false,p_allow_automations boolean default false)
returns table(message_id uuid,phone_number_id text,credentials_ref text,wa_contact_id text,msg_type text,msg_body text,template_name text,template_language text,attempt int,template_components jsonb,outbound_payload jsonb)
language plpgsql security definer set search_path=''as $$
declare claimed int;
begin
 return query select x.*,null::jsonb from public.claim_outbound_messages_v4(p_limit,p_allow_campaigns,p_allow_automations)x;
 get diagnostics claimed=row_count;
 update public.messages m set status='failed',error=private.inbox_delivery_error(m.id),locked_at=null where m.outbound_payload is not null and m.status='queued'and m.next_attempt_at<=now()and private.inbox_delivery_error(m.id)is not null;
 return query with picked as(select m.id from public.messages m where m.direction='out'and m.status='queued'and m.outbound_payload is not null and m.next_attempt_at<=now()and m.attempts<5
 order by m.created_at,m.id limit greatest(0,least(10,p_limit)-claimed)for update skip locked),
 upd as(update public.messages m set status='sending',locked_at=now(),attempts=m.attempts+1 from picked where m.id=picked.id returning m.*)
 select u.id,wc.phone_number_id,wc.credentials_ref,cv.wa_contact_id,u.type,u.body,null::text,null::text,u.attempts,null::jsonb,u.outbound_payload from upd u join public.conversations cv on cv.id=u.conversation_id join public.whatsapp_connections wc on wc.id=cv.connection_id;
end $$;
revoke all on function public.claim_outbound_messages_v5(integer,boolean,boolean)from public,anon,authenticated;grant execute on function public.claim_outbound_messages_v5(integer,boolean,boolean)to service_role;
revoke all on function private.whatsapp_public_link(text),private.whatsapp_verified_menu_stay(uuid),private.queue_whatsapp_guest_reply(uuid,uuid,text,boolean,uuid,text)from public,anon,authenticated;

create function public.whatsapp_guest_menu_context(p_property uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
begin
 if not private.has_permission(p_property,'whatsapp.use')and not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel messaging access required.'using errcode='42501';end if;
 return (select to_jsonb(c)from public.whatsapp_guest_menu c where property_id=p_property);
end $$;
revoke all on function public.whatsapp_guest_menu_context(uuid)from public,anon;grant execute on function public.whatsapp_guest_menu_context(uuid)to authenticated;

-- Include rich content in the existing authorized Inbox history for previews and links.
alter function public.inbox_workspace(uuid,jsonb)rename to inbox_workspace_before_concierge;
revoke all on function public.inbox_workspace_before_concierge(uuid,jsonb)from public,anon,authenticated,service_role;
create function public.inbox_workspace(p_property uuid,p_filters jsonb default '{}')returns jsonb language plpgsql stable security definer set search_path=''as $$
declare d jsonb;rows jsonb;
begin
 d:=public.inbox_workspace_before_concierge(p_property,p_filters);
 select coalesce(jsonb_agg(v||jsonb_build_object('outbound_payload',m.outbound_payload)order by n),'[]')into rows from jsonb_array_elements(d->'messages')with ordinality t(v,n)left join public.messages m on m.id=(v->>'id')::uuid and m.property_id=p_property;
 return jsonb_set(d,'{messages}',rows);
end $$;
revoke all on function public.inbox_workspace(uuid,jsonb)from public,anon;grant execute on function public.inbox_workspace(uuid,jsonb)to authenticated;

-- Uploads go through the staff.manage server endpoint; no browser write policy is granted.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)values('hotel-whatsapp-photos','hotel-whatsapp-photos',true,5242880,array['image/jpeg','image/png','image/webp'])on conflict(id)do nothing;
