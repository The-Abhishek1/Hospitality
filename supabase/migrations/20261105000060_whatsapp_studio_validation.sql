-- Content-reviewed drafts require resolvable public links; private stay tokens never belong in settings.
create or replace function public.whatsapp_studio_save(p_property uuid,p_request uuid,p_section text,p_id uuid,p_version integer,p_data jsonb)returns uuid
language plpgsql security definer set search_path=''as $$
declare tenant uuid;result uuid;ver integer;payload jsonb;cmd private.whatsapp_studio_commands;item jsonb;token text;body text;template_row public.whatsapp_template_drafts;purpose text;field text;old_data jsonb;settings jsonb;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel administration access required.'using errcode='42501';end if;
 if p_request is null or p_section is null or p_section not in('settings','template','journey')or p_data is null or jsonb_typeof(p_data)<>'object'or pg_column_size(p_data)>24000 then raise exception 'Invalid studio form.'using errcode='22023';end if;
 select tenant_id into tenant from public.properties where id=p_property;
 payload:=jsonb_build_object('section',p_section,'id',p_id,'version',p_version,'data',p_data);
 perform pg_advisory_xact_lock(hashtextextended('wa-studio:'||p_property::text,0));
 select * into cmd from private.whatsapp_studio_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.actor_id<>auth.uid()or cmd.payload<>payload then raise exception 'Request already used. Refresh the form.'using errcode='22023';end if;return cmd.result_id;end if;
 if p_section='settings'then
  select version,data into ver,old_data from public.whatsapp_guest_settings where property_id=p_property;
  if coalesce(ver,0)is distinct from p_version then raise exception 'Settings changed. Refresh and review.'using errcode='40001';end if;
  foreach field in array array['portal_origin','review_url','maps_url','website_url','hotel_photo_url']loop
   if coalesce(p_data->>field,'')<>''and not coalesce(private.whatsapp_studio_url(p_data->>field,field='portal_origin'),false)then raise exception 'Use valid HTTPS links (localhost HTTP is allowed for local guest portal previews).'using errcode='22023';end if;
  end loop;
  if coalesce(p_data->>'portal_origin','')<>''and(p_data->>'portal_origin'~'[?#]'or p_data->>'portal_origin'~'/s/')then raise exception 'Enter the guest portal base URL, without a stay token, query or fragment.'using errcode='22023';end if;
  if length(coalesce(p_data->>'menu_intro',''))not between 1 and 500 or jsonb_typeof(p_data->'menu_items')is distinct from 'array'or jsonb_array_length(p_data->'menu_items')not between 1 and 10 then raise exception 'Add a menu introduction and 1–10 menu options.'using errcode='22023';end if;
  if(select count(distinct value->>'action')from jsonb_array_elements(p_data->'menu_items'))<>jsonb_array_length(p_data->'menu_items')then raise exception 'Each menu action can appear once.'using errcode='22023';end if;
  for item in select * from jsonb_array_elements(p_data->'menu_items')loop
   if item->>'action'is null or item->>'action'not in('stay','documents','food','services','checkin','checkout','review','reception')or length(trim(coalesce(item->>'label','')))not between 1 and 24 or jsonb_typeof(item->'enabled')is distinct from 'boolean'then raise exception 'Check menu labels, actions and availability.'using errcode='22023';end if;
  end loop;
  insert into public.whatsapp_guest_settings(property_id,tenant_id,data)values(p_property,tenant,p_data)on conflict(property_id)do update set data=excluded.data,version=whatsapp_guest_settings.version+1,updated_at=now();result:=p_property;
 elsif p_section='template'then
  if p_id is not null then select version,data into ver,old_data from public.whatsapp_template_drafts where id=p_id and property_id=p_property;if not found then raise exception 'Template not found.'using errcode='P0002';end if;else ver:=0;end if;
  if ver is distinct from p_version then raise exception 'Template changed. Refresh and review.'using errcode='40001';end if;
  if coalesce(p_data->>'name','')!~'^[a-z][a-z0-9_]{2,127}$'or coalesce(p_data->>'language','')not in('en','en_US','en_GB','hi','ta','te','ml','kn','ar')or coalesce(p_data->>'state','')not in('draft','ready','archived')or coalesce(p_data->>'category','')not in('utility','marketing')or coalesce(p_data->>'purpose','')not in('welcome','pre_arrival','arrival','in_stay','checkout','review','hotel_guide','service_update')then raise exception 'Check template name, language, category, purpose and internal state.'using errcode='22023';end if;
  body:=trim(coalesce(p_data->>'body',''));
  if length(body)not between 10 and 1024 or length(coalesce(p_data->>'footer',''))>60 or coalesce(p_data->>'header_kind','')not in('none','text','image')or length(coalesce(p_data->>'header_text',''))>60 then raise exception 'Use 10–1024 body characters, a footer up to 60 characters and a valid header.'using errcode='22023';end if;
  if coalesce(p_data->>'header_text','')~'[{}]'or coalesce(p_data->>'footer','')~'[{}]'then raise exception 'Header and footer must be static text; use body variables instead.'using errcode='22023';end if;
  if p_data->>'header_kind'='text'and length(trim(coalesce(p_data->>'header_text','')))=0 then raise exception 'Add header text.'using errcode='22023';end if;
  for token in select m[1]from regexp_matches(body,'\{\{([a-z_]+)\}\}','g')m loop
   if token not in('guest_name','hotel_name','check_in','check_out','booking_reference','room_name','check_in_time','check_out_time','hotel_phone','request_title','request_status')then raise exception 'Unknown template variable: %',token using errcode='22023';end if;
  end loop;
  if regexp_replace(body,'\{\{[a-z_]+\}\}','','g')~'[{}]'then raise exception 'Use supported named variables such as {{guest_name}}.'using errcode='22023';end if;
  if p_data->>'header_kind'='image'and not coalesce(private.whatsapp_studio_url(p_data->>'image_url'),false)then raise exception 'Add a public HTTPS hotel image URL. Provider media upload happens during connection setup.'using errcode='22023';end if;
  if jsonb_typeof(p_data->'buttons')is distinct from 'array'or jsonb_array_length(p_data->'buttons')>3 then raise exception 'Add up to three buttons.'using errcode='22023';end if;
  if exists(select 1 from jsonb_array_elements(p_data->'buttons')where value->>'type'='quick_reply')and exists(select 1 from jsonb_array_elements(p_data->'buttons')where value->>'type'<>'quick_reply')or(select count(*)from jsonb_array_elements(p_data->'buttons')where value->>'type'<>'quick_reply')>2 then raise exception 'Use up to two URL buttons or three quick replies; do not mix them.'using errcode='22023';end if;
  for item in select * from jsonb_array_elements(p_data->'buttons')loop
   if coalesce(item->>'type','')not in('portal','review','maps','website','quick_reply')or length(trim(coalesce(item->>'text','')))not between 1 and 20 then raise exception 'Check button type and label (1–20 characters).'using errcode='22023';end if;
   if item->>'type'='portal'and coalesce(item->>'action','')not in('stay','documents','food','services','checkin','checkout')or item->>'type'='quick_reply'and coalesce(item->>'action','')not in('menu','reception','stop')then raise exception 'Choose a supported button action.'using errcode='22023';end if;
  end loop;
  if p_data->>'state'='ready'then
   select data into settings from public.whatsapp_guest_settings where property_id=p_property;
   for item in select * from jsonb_array_elements(p_data->'buttons')where value->>'type'<>'quick_reply'loop
    field:=case item->>'type'when 'portal'then 'portal_origin'when 'review'then 'review_url'when 'maps'then 'maps_url'when 'website'then 'website_url'end;
    if not coalesce(private.whatsapp_studio_url(settings->>field),false)then raise exception 'Configure a public HTTPS % link before marking this content reviewed.',item->>'type'using errcode='22023';end if;
   end loop;
  end if;
  if p_data->>'state'='archived'and exists(select 1 from public.whatsapp_guest_journeys where property_id=p_property and template_id=p_id and prepared)then raise exception 'Unprepare linked journeys before archiving this template.'using errcode='22023';end if;
  if p_id is null then insert into public.whatsapp_template_drafts(property_id,tenant_id,name,language,state,purpose,category,data)values(p_property,tenant,p_data->>'name',p_data->>'language',p_data->>'state',p_data->>'purpose',p_data->>'category',p_data)returning id into result;
  else update public.whatsapp_template_drafts set name=p_data->>'name',language=p_data->>'language',state=p_data->>'state',purpose=p_data->>'purpose',category=p_data->>'category',data=p_data,version=version+1,updated_at=now()where id=p_id and property_id=p_property;result:=p_id;end if;
 else
  if coalesce(p_data->>'event','')not in('booking_created','before_arrival','checked_in','before_checkout','checked_out','request_completed')or jsonb_typeof(p_data->'prepared')is distinct from 'boolean'or jsonb_typeof(p_data->'sources')is distinct from 'array'or jsonb_array_length(p_data->'sources')not between 1 and 3 then raise exception 'Choose a journey event and booking sources.'using errcode='22023';end if;
  if exists(select 1 from jsonb_array_elements_text(p_data->'sources')s where s not in('direct','walk_in','ota'))or(select count(distinct s)from jsonb_array_elements_text(p_data->'sources')s)<>jsonb_array_length(p_data->'sources')then raise exception 'Choose distinct direct, walk-in or OTA sources.'using errcode='22023';end if;
  if coalesce(p_data->>'delay_minutes','')!~'^[0-9]{1,5}$'or(p_data->>'delay_minutes')::integer>10080 then raise exception 'Use a delay of 0–10080 minutes.'using errcode='22023';end if;
  select * into template_row from public.whatsapp_template_drafts where id=(p_data->>'template_id')::uuid and property_id=p_property;
  if not found then raise exception 'Choose a template from this hotel.'using errcode='22023';end if;
  purpose:=case p_data->>'event'when 'booking_created'then 'welcome'when 'before_arrival'then 'pre_arrival'when 'checked_in'then 'in_stay'when 'before_checkout'then 'checkout'when 'checked_out'then 'review'when 'request_completed'then 'service_update'end;
  if template_row.purpose<>purpose or template_row.state='archived'or(p_data->>'prepared')::boolean and template_row.state<>'ready'then raise exception 'Choose a matching, content-reviewed template before preparing this journey.'using errcode='22023';end if;
  select version,to_jsonb(j)into ver,old_data from public.whatsapp_guest_journeys j where property_id=p_property and event=p_data->>'event';
  if coalesce(ver,0)is distinct from p_version then raise exception 'Journey changed. Refresh and review.'using errcode='40001';end if;
  insert into public.whatsapp_guest_journeys(property_id,tenant_id,event,template_id,sources,delay_minutes,prepared)values(p_property,tenant,p_data->>'event',template_row.id,p_data->'sources',(p_data->>'delay_minutes')::integer,(p_data->>'prepared')::boolean)on conflict(property_id,event)do update set template_id=excluded.template_id,sources=excluded.sources,delay_minutes=excluded.delay_minutes,prepared=excluded.prepared,version=whatsapp_guest_journeys.version+1,updated_at=now()returning id into result;
 end if;
 insert into public.whatsapp_studio_events(tenant_id,property_id,actor_id,section,record_id,details)values(tenant,p_property,auth.uid(),p_section,result,jsonb_build_object('before',old_data,'after',p_data));
 insert into private.whatsapp_studio_commands(property_id,request_id,actor_id,payload,result_id)values(p_property,p_request,auth.uid(),payload,result);return result;
end $$;

alter table private.whatsapp_studio_commands add constraint whatsapp_studio_command_property foreign key(property_id)references public.properties(id)on delete cascade;
