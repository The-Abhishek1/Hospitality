-- Owner-defined categories and services; published services send approved template snapshots.
alter table public.message_templates add column service_supported boolean not null default false;
alter table public.messages add column menu_template_fingerprint text;
create table public.whatsapp_template_assets(property_id uuid references public.properties(id)on delete cascade,provider_template_id text not null,image_url text not null,primary key(property_id,provider_template_id));
alter table public.whatsapp_template_assets enable row level security;
create policy template_assets_read on public.whatsapp_template_assets for select to authenticated using(private.has_permission(property_id,'whatsapp.use')or private.has_permission(property_id,'staff.manage'));
revoke all on public.whatsapp_template_assets from anon,authenticated;grant select on public.whatsapp_template_assets to authenticated;grant all on public.whatsapp_template_assets to service_role;

create function private.validate_grouped_menu(p_property uuid,p_data jsonb,p_enabled boolean)returns void language plpgsql security definer set search_path=''as $$
declare cat jsonb;s jsonb;t public.message_templates;total int:=0;active int:=0;ids text[]:='{}';cid text[]:='{}';
begin
 if jsonb_typeof(p_data->'categories')is distinct from 'array'or jsonb_array_length(p_data->'categories')not between 1 and 30 then raise exception 'Add between 1 and 30 categories.'using errcode='22023';end if;
 for cat in select *from jsonb_array_elements(p_data->'categories')loop
  if coalesce(cat->>'id','')!~'^[a-f0-9-]{36}$'or cat->>'id'=any(cid)or jsonb_typeof(cat->'label')is distinct from 'string'or length(trim(cat->>'label'))not between 1 and 24 or jsonb_typeof(cat->'enabled')is distinct from 'boolean'or jsonb_typeof(cat->'services')is distinct from 'array'or jsonb_array_length(cat->'services')>100 then raise exception 'Check category names, IDs and services.'using errcode='22023';end if;cid:=array_append(cid,cat->>'id');
  for s in select *from jsonb_array_elements(cat->'services')loop
   total:=total+1;
   if total>100 or coalesce(s->>'id','')!~'^[a-f0-9-]{36}$'or s->>'id'=any(ids)or jsonb_typeof(s->'label')is distinct from 'string'or length(trim(s->>'label'))not between 1 and 24 or jsonb_typeof(s->'enabled')is distinct from 'boolean'or coalesce(s->>'action','')not in('reply','stay','documents','food','services','checkin','checkout','location','photos','review','website','reception')then raise exception 'Use unique services, labels up to 24 characters and a supported action (100 services maximum).'using errcode='22023';end if;ids:=array_append(ids,s->>'id');
   if coalesce(s->>'template_id','')<>''then
    if s->>'template_id'!~'^[a-f0-9-]{36}$'then raise exception 'Choose a valid template.'using errcode='22023';end if;
    select *into t from public.message_templates where id=(s->>'template_id')::uuid and property_id=p_property;
    if not found then raise exception 'Choose a template belonging to this hotel.'using errcode='22023';end if;
   else t:=null;end if;
   if cat->>'enabled'='true'and s->>'enabled'='true'then
    active:=active+1;
    if p_enabled and(t.id is null or t.provider_status<>'APPROVED'or not t.service_supported or t.provider_checked_at<now()-interval '24 hours'or t.provider_waba_id is distinct from(select waba_id from public.whatsapp_connections where property_id=p_property and status='active'))then raise exception 'Assign a current approved service template to each enabled service before publishing.'using errcode='22023';end if;
    if p_enabled and s->>'action'in('stay','documents','food','services','checkin','checkout')and not(t.parameter_names?'portal_url')then raise exception 'Private guest-page services need a template containing {{portal_url}}.'using errcode='22023';end if;
    if p_enabled and exists(select 1 from jsonb_array_elements(t.provider_definition->'components')h where h->>'type'='HEADER'and h->>'format'='IMAGE')and not exists(select 1 from public.whatsapp_template_assets a where a.property_id=p_property and a.provider_template_id=t.provider_template_id)then raise exception 'Upload a delivery image for this image-header template before publishing.'using errcode='22023';end if;
   end if;
  end loop;
 end loop;
 if p_enabled and active=0 then raise exception 'Enable at least one service before publishing.'using errcode='22023';end if;
end $$;
revoke all on function private.validate_grouped_menu(uuid,jsonb,boolean)from public,anon,authenticated,service_role;
create or replace function public.save_whatsapp_guest_menu(p_property uuid,p_version integer,p_enabled boolean,p_data jsonb)returns void
language plpgsql security definer set search_path=''as $$
declare row public.whatsapp_guest_menu;item jsonb;key text;enabled_count int;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel administration access required.'using errcode='42501';end if;
 if p_enabled is null or p_data is null or jsonb_typeof(p_data)<>'object'or pg_column_size(p_data)>120000 then raise exception 'Check the guest menu form.'using errcode='22023';end if;
 if p_data?'categories'then perform private.validate_grouped_menu(p_property,p_data,p_enabled);end if;
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
 if enabled_count not between 1 and 10 and not(p_data?'categories')then raise exception 'Invalid compatibility menu.'using errcode='22023';end if;
 foreach key in array array['maps_url','review_url','website_url']loop
  if p_data?key and jsonb_typeof(p_data->key)is distinct from 'string'then raise exception 'Hotel links must be text.'using errcode='22023';end if;
  if coalesce(p_data->>key,'')<>''and not private.whatsapp_public_link(p_data->>key)then raise exception 'Use public HTTPS hotel links.'using errcode='22023';end if;
 end loop;
 if jsonb_typeof(p_data->'photos')is distinct from 'array'or jsonb_array_length(p_data->'photos')>5 then raise exception 'Add up to five public hotel photos.'using errcode='22023';end if;
 for item in select *from jsonb_array_elements(p_data->'photos')loop
  if not private.whatsapp_public_link(item->>'url')or jsonb_typeof(item->'caption')is distinct from 'string'or length(item->>'caption')>1024 then raise exception 'Each hotel photo needs a public HTTPS image link and caption up to 1024 characters.'using errcode='22023';end if;
 end loop;
 if p_enabled and not(p_data?'categories')and exists(select 1 from jsonb_array_elements(p_data->'items')i where i->>'enabled'='true'and(case i->>'action'when'location'then coalesce(p_data->>'maps_url','')=''when'review'then coalesce(p_data->>'review_url','')=''when'website'then coalesce(p_data->>'website_url','')=''when'photos'then jsonb_array_length(p_data->'photos')=0 else false end))then raise exception 'Configure the links and photos for enabled menu options.'using errcode='22023';end if;
 insert into public.whatsapp_guest_menu(property_id,enabled,data,updated_by)values(p_property,p_enabled,p_data,auth.uid())on conflict(property_id)do update set enabled=excluded.enabled,data=excluded.data,version=whatsapp_guest_menu.version+1,updated_at=now(),updated_by=auth.uid();
 insert into public.whatsapp_guest_settings(property_id,tenant_id,data)select p_property,p.tenant_id,jsonb_build_object('maps_url',coalesce(p_data->>'maps_url',''),'review_url',coalesce(p_data->>'review_url',''),'website_url',coalesce(p_data->>'website_url',''),'hotel_photo_url',coalesce(p_data#>>'{photos,0,url}',''))from public.properties p where p.id=p_property on conflict(property_id)do update set data=whatsapp_guest_settings.data||excluded.data,version=whatsapp_guest_settings.version+1,updated_at=now();
end $$;
create or replace function public.sync_whatsapp_provider_templates(p_connection uuid,p_waba text,p_templates jsonb)returns integer
language plpgsql security definer set search_path=''as $$
declare c public.whatsapp_connections;t jsonb;n integer:=0;approved boolean;
begin
 select *into c from public.whatsapp_connections where id=p_connection and status='active'for update;
 if c.id is null or c.waba_id<>p_waba or jsonb_typeof(p_templates)<>'array'or pg_column_size(p_templates)>2000000 then raise exception 'Invalid template sync'using errcode='22023';end if;
 update public.message_templates set status='rejected',automation_supported=false,service_supported=false,campaign_supported=false,provider_status='MISSING',provider_checked_at=now()where property_id=c.property_id and provider_template_id is not null;
 for t in select *from jsonb_array_elements(p_templates)loop
  if t->>'category'not in('utility','marketing')then continue;end if;
  approved:=t->>'provider_status'='APPROVED'and(coalesce((t->>'supported')::boolean,false)or coalesce((t->>'service_supported')::boolean,false));
  insert into public.message_templates(tenant_id,property_id,name,language,category,status,body,automation_supported,campaign_supported,provider_template_id,provider_waba_id,provider_status,provider_definition,provider_fingerprint,provider_checked_at,parameter_names,service_supported)
  values(c.tenant_id,c.property_id,t->>'name',t->>'language',t->>'category',case when approved then'approved'else'pending'end,t->>'body',approved and coalesce((t->>'supported')::boolean,false),approved and coalesce((t->>'supported')::boolean,false)and t->>'category'='marketing'and jsonb_array_length(t->'parameter_names')=0,t->>'provider_id',p_waba,t->>'provider_status',t->'definition',encode(sha256(convert_to((t->'definition')::text,'utf8')),'hex'),now(),t->'parameter_names',approved and coalesce((t->>'service_supported')::boolean,false))
  on conflict(property_id,name,language)do update set category=excluded.category,status=excluded.status,body=excluded.body,automation_supported=excluded.automation_supported,campaign_supported=excluded.campaign_supported,provider_template_id=excluded.provider_template_id,provider_waba_id=excluded.provider_waba_id,provider_status=excluded.provider_status,provider_definition=excluded.provider_definition,provider_fingerprint=excluded.provider_fingerprint,provider_checked_at=excluded.provider_checked_at,parameter_names=excluded.parameter_names,service_supported=excluded.service_supported;
  n:=n+1;
 end loop;
 update public.whatsapp_connections set templates_sync_after=now()+interval '15 minutes'where id=c.id;
 return n;
end $$;
alter function private.queue_whatsapp_guest_reply(uuid,uuid,text,boolean,uuid,text)rename to queue_whatsapp_guest_reply_flat;
revoke all on function private.queue_whatsapp_guest_reply_flat(uuid,uuid,text,boolean,uuid,text)from public,anon,authenticated,service_role;
create function private.queue_whatsapp_guest_reply(p_conversation uuid,p_request uuid,p_action text,p_automatic boolean,p_source uuid,p_origin text)returns uuid language plpgsql security definer set search_path=''as $$
declare c public.conversations;cfg public.whatsapp_guest_menu;cat jsonb;s jsonb;rows jsonb:='[]';list jsonb;part jsonb;payload jsonb;components jsonb:='[]';params jsonb:='[]';vars jsonb;t public.message_templates;rid uuid;av int;token text;url text;body text;name text;value text;mid uuid;sender text;page int:=0;total int;offset_n int;head text;action text:=p_action;g public.guests;p public.properties;
begin
 select *into c from public.conversations where id=p_conversation for update;
 select *into cfg from public.whatsapp_guest_menu where property_id=c.property_id;
 if not(cfg.data?'categories')then return private.queue_whatsapp_guest_reply_flat(p_conversation,p_request,p_action,p_automatic,p_source,p_origin);end if;
 if not private.tenant_is_active(c.tenant_id)or c.status<>'open'or private.is_opted_out(c.property_id,c.wa_contact_id)or c.last_inbound_at is null or c.last_inbound_at<now()-interval '24 hours'then raise exception 'An active hotel, open conversation and current reply window are required.'using errcode='22023';end if;
 if p_automatic and(not cfg.enabled or c.human_handoff)then return null;end if;
 select phone_number_id into sender from public.whatsapp_connections where id=c.connection_id and status='active';if sender is null then raise exception 'WhatsApp is disconnected.'using errcode='22023';end if;
 if p_request is not null then select id into mid from public.messages where conversation_id=c.id and creation_request_id=p_request;if found then return mid;end if;end if;
 if action in('menu','reception','location','photos','review','website','stay','documents','food','services','checkin','checkout')then
  if action<>'menu'then
   select x into s from jsonb_array_elements(cfg.data->'categories')k cross join lateral jsonb_array_elements(k->'services')x where k->>'enabled'='true'and x->>'enabled'='true'and x->>'action'=action limit 1;
   if s is null then return null;end if;action:='service:'||(s->>'id');
  end if;
 end if;
 if action='menu'or action~'^root:[0-9]{1,3}$'or action~'^category:[a-f0-9-]{36}:[0-9]{1,3}$'then
  if action like 'category:%'then
   select k into cat from jsonb_array_elements(cfg.data->'categories')k where k->>'id'=split_part(action,':',2)and k->>'enabled'='true';if cat is null then return null;end if;
   page:=split_part(action,':',3)::int;head:=cat->>'label';
   select coalesce(jsonb_agg(jsonb_build_object('id','guest:v:'||cfg.version||':service:'||(x->>'id'),'title',x->>'label')order by n),'[]')into list from jsonb_array_elements(cat->'services')with ordinality a(x,n)where x->>'enabled'='true';
  else
   if action<>'menu'then page:=split_part(action,':',2)::int;end if;head:='Hotel services';
   select coalesce(jsonb_agg(jsonb_build_object('id','guest:v:'||cfg.version||':category:'||(k->>'id')||':0','title',k->>'label')order by n),'[]')into list from jsonb_array_elements(cfg.data->'categories')with ordinality a(k,n)where k->>'enabled'='true'and exists(select 1 from jsonb_array_elements(k->'services')x where x->>'enabled'='true');
  end if;
  total:=jsonb_array_length(list);if total=0 then return null;end if;page:=least(page,(total-1)/7);offset_n:=page*7;
  select coalesce(jsonb_agg(x order by n),'[]')into rows from jsonb_array_elements(list)with ordinality a(x,n)where n>offset_n and n<=offset_n+7;
  if page>0 then rows:=rows||jsonb_build_array(jsonb_build_object('id','guest:v:'||cfg.version||':'||case when cat is null then'root:'else'category:'||(cat->>'id')||':'end||(page-1),'title','← Previous'));end if;
  if offset_n+7<total then rows:=rows||jsonb_build_array(jsonb_build_object('id','guest:v:'||cfg.version||':'||case when cat is null then'root:'else'category:'||(cat->>'id')||':'end||(page+1),'title','More options →'));end if;
  if cat is not null then rows:=rows||jsonb_build_array(jsonb_build_object('id','guest:v:'||cfg.version||':root:0','title','← Main menu'));end if;
  body:=case when cat is null then cfg.data->>'intro'else 'Choose a service in '||head||'.'end;
  payload:=jsonb_build_object('type','interactive','interactive',jsonb_build_object('type','list','body',jsonb_build_object('text',body),'action',jsonb_build_object('button','Choose an option','sections',jsonb_build_array(jsonb_build_object('title',head,'rows',rows)))));
 else
  if action!~'^service:[a-f0-9-]{36}$'then return null;end if;
  select x into s from jsonb_array_elements(cfg.data->'categories')k cross join lateral jsonb_array_elements(k->'services')x where k->>'enabled'='true'and x->>'enabled'='true'and x->>'id'=split_part(action,':',2);
  if s is null then return null;end if;
  select *into t from public.message_templates where id=nullif(s->>'template_id','')::uuid and property_id=c.property_id and service_supported and provider_status='APPROVED'and provider_checked_at>now()-interval '24 hours'and provider_waba_id=(select waba_id from public.whatsapp_connections where id=c.connection_id);
  if t.id is null then raise exception 'Service template needs approval or synchronization.'using errcode='22023';end if;
  select *into p from public.properties where id=c.property_id;
  vars:=jsonb_build_object('hotel_name',p.name,'hotel_phone',coalesce(nullif(p.contact_phone,''),'Contact reception'),'review_url',(select data->>'review_url'from public.whatsapp_guest_settings where property_id=c.property_id));
  if exists(select 1 from jsonb_array_elements_text(t.parameter_names)n where n not in('hotel_name','hotel_phone','review_url'))then
   rid:=private.whatsapp_verified_menu_stay(c.id);
   if rid is null then
    body:='Reception needs to verify your stay and WhatsApp number before sharing private guest information. Please contact reception for assistance.';payload:=jsonb_build_object('type','text','text',jsonb_build_object('body',body));t:=null;
   else
    select *into g from public.guests where id=c.guest_id;select version into av from public.whatsapp_guest_authorizations where conversation_id=c.id and status='granted';
    vars:=vars||(select jsonb_build_object('guest_name',g.full_name,'booking_reference',upper(left(replace(r.id::text,'-',''),8)),'check_in',r.check_in::text,'check_out',r.check_out::text,'room_name',coalesce((select string_agg(u.name,', ')from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.reservation_id=r.id and h.active),'Not assigned'))from public.reservations r where id=rid);
    if t.parameter_names?'portal_url'then
     if not private.whatsapp_public_link(p_origin)or p_origin~'[?#]'or p_origin~'/s/'then raise exception 'Secure guest portal unavailable.'using errcode='22023';end if;
     token:=encode(extensions.gen_random_bytes(32),'hex');insert into public.guest_access_tokens(tenant_id,property_id,reservation_id,token_hash,expires_at)values(c.tenant_id,c.property_id,rid,encode(sha256(convert_to(token,'utf8')),'hex'),now()+interval '7 days');
     url:=rtrim(p_origin,'/')||'/s/'||token||case s->>'action'when'documents'then'?view=documents'when'food'then'?view=food'when'services'then'?view=services'when'checkin'then'?intent=checkin'when'checkout'then'?intent=checkout'else''end;vars:=vars||jsonb_build_object('portal_url',url);
    end if;
   end if;
  end if;
  if t.id is not null then
   body:=t.body;
   for name in select jsonb_array_elements_text(t.parameter_names)loop value:=regexp_replace(trim(coalesce(vars->>name,'')),'[\n\r\t]+',' ','g');if value=''then raise exception 'Required service field unavailable.'using errcode='22023';end if;params:=params||jsonb_build_array(jsonb_build_object('type','text','parameter_name',name,'text',value));body:=regexp_replace(body,'\{\{\s*'||name||'\s*\}\}',value,'g');end loop;
   if jsonb_array_length(params)>0 then components:=components||jsonb_build_array(jsonb_build_object('type','body','parameters',params));end if;
   if exists(select 1 from jsonb_array_elements(t.provider_definition->'components')h where h->>'type'='HEADER'and h->>'format'='IMAGE')then
    select image_url into url from public.whatsapp_template_assets where property_id=c.property_id and provider_template_id=t.provider_template_id;if not private.whatsapp_public_link(url)then raise exception 'Service template image unavailable.'using errcode='22023';end if;
    components:=jsonb_build_array(jsonb_build_object('type','header','parameters',jsonb_build_array(jsonb_build_object('type','image','image',jsonb_build_object('link',url)))))||components;
   end if;
   payload:=jsonb_build_object('type','template','template',jsonb_build_object('name',t.name,'language',jsonb_build_object('code',t.language),'components',components));
   if s->>'action'='reception'then update public.conversations set human_handoff=true,version=version+1 where id=c.id;end if;
  end if;
 end if;
 insert into public.messages(tenant_id,property_id,conversation_id,direction,type,body,template_id,status,sent_by,creation_request_id,outbound_payload,template_components,guest_menu_version,guest_menu_action,guest_menu_automatic,guest_reply_to,guest_stay_id,guest_authorization_version,guest_sender_id,menu_template_fingerprint)
 values(c.tenant_id,c.property_id,c.id,'out',payload->>'type',body,t.id,'queued',case when p_automatic then null else auth.uid()end,p_request,payload,components,cfg.version,case when s->>'action'='reception'and t.id is not null then'reception'else action end,p_automatic,p_source,rid,av,sender,t.provider_fingerprint)on conflict do nothing returning id into mid;
 update public.conversations set last_message_at=now()where id=c.id;return mid;
end $$;
revoke all on function private.queue_whatsapp_guest_reply(uuid,uuid,text,boolean,uuid,text)from public,anon,authenticated,service_role;

create function private.decode_grouped_action(command text,version int)returns text language sql immutable set search_path=''as $$
 select case when command~'^guest:v:[0-9]+:(root:[0-9]{1,3}|category:[a-f0-9-]{36}:[0-9]{1,3}|service:[a-f0-9-]{36})$'then case when split_part(command,':',3)=version::text then substring(command from length('guest:v:'||version||':')+1)else'menu'end else null end
$$;
revoke all on function private.decode_grouped_action(text,integer)from public,anon,authenticated,service_role;
create or replace function public.dispatch_whatsapp_guest_replies(p_limit integer default 50,p_portal_origin text default null)returns integer
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
  if cfg.data?'categories'and job.command like 'guest:v:%'then action:=private.decode_grouped_action(job.command,cfg.version);end if;
  if cfg.data?'categories'and job.command~'^(10|[1-9])$'then
   select private.decode_grouped_action(outbound_payload#>>array['interactive','action','sections','0','rows',(job.command::int-1)::text,'id'],cfg.version)into action from public.messages where conversation_id=c.id and outbound_payload#>>'{interactive,type}'='list'and status in('sent','delivered','read')and guest_menu_version=cfg.version order by created_at desc,id desc limit 1;
  end if;
  if not(cfg.data?'categories')and action is null and job.command~'^(10|[1-9])$'and exists(select 1 from public.messages where conversation_id=c.id and guest_menu_action='menu'and guest_menu_version=cfg.version and status in('sent','delivered','read')and created_at>now()-interval '24 hours')then
   select i->>'action'into action from jsonb_array_elements(cfg.data->'items')i where i->>'enabled'='true'offset(job.command::int-1)limit 1;
  end if;
  if action is null then continue;end if;
  if not(cfg.data?'categories')and action<>'menu'and not exists(select 1 from jsonb_array_elements(cfg.data->'items')where value->>'action'=action and value->>'enabled'='true')then continue;end if;
  -- Repeated provider events and repeated greetings within a short interval do not flood the guest.
  if action='menu'and exists(select 1 from public.messages where conversation_id=c.id and guest_menu_action='menu'and created_at>now()-interval '30 seconds'and status<>'failed')then continue;end if;
  begin
   mid:=private.queue_whatsapp_guest_reply(c.id,null,action,true,job.message_id,p_portal_origin);if mid is not null then sent:=sent+1;end if;
  exception when sqlstate '22023'then null;end;
 end loop;
 return sent;
end $$;
alter function private.inbox_delivery_error(uuid)rename to inbox_delivery_error_before_grouped;
create function private.inbox_delivery_error(p_message uuid)returns text language plpgsql stable security definer set search_path=''as $$
declare m public.messages;c public.conversations;t public.message_templates;cfg public.whatsapp_guest_menu;
begin
 select *into m from public.messages where id=p_message;
 if m.menu_template_fingerprint is null then
  if m.type='template'and m.outbound_payload is null and exists(select 1 from public.message_templates where id=m.template_id and provider_template_id is not null and not automation_supported)then return 'Use the assigned menu service to send this rich template.';end if;
  return private.inbox_delivery_error_before_grouped(p_message);
 end if;
 select *into c from public.conversations where id=m.conversation_id;select *into cfg from public.whatsapp_guest_menu where property_id=m.property_id;
 if not private.tenant_is_active(m.tenant_id)or private.is_opted_out(m.property_id,c.wa_contact_id)then return 'Hotel unavailable or guest opted out.';end if;
 if c.status<>'open'or c.last_inbound_at<now()-interval '24 hours'or c.last_inbound_at is null then return 'Guest reply window closed.';end if;
 if cfg.version is distinct from m.guest_menu_version then return 'Published services changed. Send a fresh reply.';end if;
 if m.guest_menu_automatic and(not cfg.enabled or c.human_handoff and m.guest_menu_action<>'reception')then return 'Automatic replies paused or handed to reception.';end if;
 if not exists(select 1 from public.whatsapp_connections where id=c.connection_id and phone_number_id=m.guest_sender_id and status='active')then return 'Guest reply sender changed.';end if;
 select *into t from public.message_templates where id=m.template_id and property_id=m.property_id and service_supported and provider_status='APPROVED'and provider_checked_at>now()-interval '24 hours'and provider_fingerprint=m.menu_template_fingerprint and provider_waba_id=(select waba_id from public.whatsapp_connections where id=c.connection_id);
 if t.id is null then return 'Assigned template changed, expired or lost approval.';end if;
 if exists(select 1 from jsonb_array_elements(coalesce(m.template_components,'[]'))h where h->>'type'='header'and h#>>'{parameters,0,image,link}'is distinct from(select image_url from public.whatsapp_template_assets where property_id=m.property_id and provider_template_id=t.provider_template_id))then return 'Template delivery image changed.';end if;
 if m.guest_stay_id is not null and(m.guest_stay_id is distinct from private.whatsapp_verified_menu_stay(c.id)or not exists(select 1 from public.whatsapp_guest_authorizations where conversation_id=c.id and version=m.guest_authorization_version and status='granted'))then return 'Private guest access changed. Verify the stay again.';end if;
 return null;
end $$;
revoke all on function private.inbox_delivery_error(uuid)from public,anon,authenticated,service_role;
update public.message_templates set service_supported=true where automation_supported and not exists(select 1 from jsonb_array_elements_text(parameter_names)n where n not in('guest_name','hotel_name','hotel_phone','portal_url','booking_reference','check_in','check_out','room_name','review_url'));
create function public.whatsapp_service_templates(p_property uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
begin
 if not private.has_permission(p_property,'staff.manage')and not private.has_permission(p_property,'whatsapp.use')then raise exception 'Hotel messaging access required.'using errcode='42501';end if;
 return(select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'name',t.name,'body',t.body,'language',t.language,'status',t.provider_status,'supported',t.service_supported,'checked_at',t.provider_checked_at,'parameters',t.parameter_names,'definition',t.provider_definition,'image_url',a.image_url)order by t.name),'[]')from public.message_templates t left join public.whatsapp_template_assets a on a.property_id=t.property_id and a.provider_template_id=t.provider_template_id where t.property_id=p_property and t.provider_waba_id=(select waba_id from public.whatsapp_connections where property_id=p_property));
end $$;
revoke all on function public.whatsapp_service_templates(uuid)from public,anon;grant execute on function public.whatsapp_service_templates(uuid)to authenticated;

create or replace function public.inbox_send(p_conversation uuid,p_request uuid,p_body text default null,p_template uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare c public.conversations;m uuid;t public.message_templates;conn_status text;
begin
 c:=private.lock_conversation(p_conversation,'whatsapp.use');
 if p_request is null then raise exception 'Reload the reply form and try again.' using errcode='22023';end if;
 select id into m from public.messages where conversation_id=c.id and creation_request_id=p_request;
 if found then return m;end if;
 select status into conn_status from public.whatsapp_connections where id=c.connection_id;
 if conn_status is distinct from 'active' then raise exception 'WhatsApp messaging is not enabled for this hotel.' using errcode='22023';end if;
 if c.status<>'open' then raise exception 'Reopen the conversation before replying.' using errcode='22023';end if;
 if private.is_opted_out(c.property_id,c.wa_contact_id) then raise exception 'This contact opted out. Messaging is blocked until they opt in again.' using errcode='22023';end if;
 if p_template is not null then
  select * into t from public.message_templates where id=p_template and property_id=c.property_id and status='approved';
  if not found then raise exception 'Choose an approved template for this hotel.' using errcode='22023';end if;
  if t.provider_template_id is not null and not t.automation_supported then raise exception 'Send rich templates through an assigned guest-menu service.'using errcode='22023';end if;
  if strpos(t.body,'{{')>0 then raise exception 'Templates with variables are not supported yet.' using errcode='22023';end if;
 else
  if length(trim(coalesce(p_body,''))) not between 1 and 4096 then raise exception 'Write a reply between 1 and 4096 characters.' using errcode='22023';end if;
  if c.last_inbound_at is null or c.last_inbound_at<now()-interval '24 hours' then raise exception 'The reply window has closed. Choose an approved template.' using errcode='22023';end if;
 end if;
 insert into public.messages(tenant_id,property_id,conversation_id,direction,type,body,template_id,status,sent_by,creation_request_id)
 values(c.tenant_id,c.property_id,c.id,'out',case when p_template is null then 'text' else 'template' end,case when p_template is null then trim(p_body) else t.body end,p_template,'queued',auth.uid(),p_request) returning id into m;
 update public.conversations set last_message_at=now() where id=c.id;
 return m;
end $$;
alter function public.inbox_workspace(uuid,jsonb)rename to inbox_workspace_before_grouped;
revoke all on function public.inbox_workspace_before_grouped(uuid,jsonb)from public,anon,authenticated,service_role;
create function public.inbox_workspace(p_property uuid,p_filters jsonb default '{}')returns jsonb language plpgsql stable security definer set search_path=''as $$
declare d jsonb;ts jsonb;
begin
 d:=public.inbox_workspace_before_grouped(p_property,p_filters);
 select coalesce(jsonb_agg(v||jsonb_build_object('supported',coalesce((v->>'supported')::boolean,false)and(t.provider_template_id is null or t.automation_supported))),'[]')into ts from jsonb_array_elements(d->'templates')v join public.message_templates t on t.id=(v->>'id')::uuid and t.property_id=p_property;
 return jsonb_set(d,'{templates}',ts);
end $$;
revoke all on function public.inbox_workspace(uuid,jsonb)from public,anon;grant execute on function public.inbox_workspace(uuid,jsonb)to authenticated;
