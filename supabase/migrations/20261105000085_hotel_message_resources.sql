-- Shared hotel information is edited independently from guest menus and templates.
create table public.hotel_message_photos(
 id uuid primary key default gen_random_uuid(),property_id uuid not null references public.properties(id)on delete cascade,
 name text not null check(length(name)between 1 and 120),url text not null,storage_path text,mime_type text,
 archived boolean not null default false,created_at timestamptz not null default now(),unique(property_id,url)
);
alter table public.hotel_message_photos enable row level security;
create policy hotel_photos_read on public.hotel_message_photos for select to authenticated using(private.has_permission(property_id,'staff.manage')and exists(select 1 from public.properties p where p.id=property_id and private.tenant_is_active(p.tenant_id)));
revoke all on public.hotel_message_photos from anon,authenticated;grant select on public.hotel_message_photos to authenticated;grant all on public.hotel_message_photos to service_role;
-- Retain photo references from existing menus and templates. No files or templates are changed.
insert into public.hotel_message_photos(property_id,name,url,mime_type)
select m.property_id,coalesce(nullif(left(x->>'caption',120),''),'Hotel photo'),x->>'url',case when x->>'url'~*'\.jpe?g$'then'image/jpeg'when x->>'url'~*'\.png$'then'image/png'else null end
from public.whatsapp_guest_menu m cross join lateral jsonb_array_elements(coalesce(m.data->'photos','[]'))x
where private.whatsapp_public_link(x->>'url')on conflict(property_id,url)do nothing;
insert into public.hotel_message_photos(property_id,name,url,mime_type)
select property_id,'Template photo',image_url,case when image_url like '%.jpg'then'image/jpeg'when image_url like '%.png'then'image/png'else null end
from public.whatsapp_template_assets where private.whatsapp_public_link(image_url)on conflict(property_id,url)do nothing;
insert into public.whatsapp_guest_settings(property_id,tenant_id,data)
select m.property_id,p.tenant_id,jsonb_build_object('maps_url',coalesce(m.data->>'maps_url',''),'review_url',coalesce(m.data->>'review_url',''),'website_url',coalesce(m.data->>'website_url',''))
from public.whatsapp_guest_menu m join public.properties p on p.id=m.property_id on conflict(property_id)do nothing;

create function public.hotel_message_resources(p_property uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare s public.whatsapp_guest_settings;
begin
 if not private.has_permission(p_property,'staff.manage')or not exists(select 1 from public.properties p where p.id=p_property and private.tenant_is_active(p.tenant_id))then raise exception 'Hotel administrator access required.'using errcode='42501';end if;
 select *into s from public.whatsapp_guest_settings where property_id=p_property;
 return jsonb_build_object('version',coalesce(s.version,0),'links',jsonb_build_object('maps_url',coalesce(s.data->>'maps_url',''),'review_url',coalesce(s.data->>'review_url',''),'website_url',coalesce(s.data->>'website_url','')),
 'photos',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'url',url,'mime_type',mime_type)order by created_at desc,id)from public.hotel_message_photos where property_id=p_property and not archived),'[]'));
end $$;
revoke all on function public.hotel_message_resources(uuid)from public,anon;grant execute on function public.hotel_message_resources(uuid)to authenticated;

create function public.save_hotel_message_links(p_property uuid,p_version integer,p_links jsonb,p_reason text)returns integer language plpgsql security definer set search_path=''as $$
declare s public.whatsapp_guest_settings;k text;links jsonb:='{}';tenant uuid;actor text;ver integer;before_links jsonb;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel administrator access required.'using errcode='42501';end if;
 select tenant_id into tenant from public.properties where id=p_property;
 if not private.tenant_is_active(tenant)then raise exception 'Hotel account inactive.'using errcode='42501';end if;
 if p_reason is null or length(trim(p_reason))not between 3 and 500 or jsonb_typeof(p_links)is distinct from 'object'or pg_column_size(p_links)>10000 then raise exception 'Check the hotel links and add a change reason.'using errcode='22023';end if;
 foreach k in array array['maps_url','review_url','website_url']loop
  if jsonb_typeof(p_links->k)is distinct from 'string'or length(p_links->>k)>2000 or(p_links->>k<>''and(not private.whatsapp_public_link(p_links->>k)or p_links->>k~'/s/'or p_links->>k~*'[?&](access_token|token)='))then raise exception 'Use public HTTPS hotel links. Personal guest links do not belong here.'using errcode='22023';end if;
  links:=links||jsonb_build_object(k,trim(p_links->>k));
 end loop;
 perform pg_advisory_xact_lock(hashtextextended('wa-studio:'||p_property::text,0));
 perform pg_advisory_xact_lock(hashtextextended('guest-menu:'||p_property::text,0));
 select *into s from public.whatsapp_guest_settings where property_id=p_property for update;
 if p_version is null or coalesce(s.version,0)<>p_version then raise exception 'Hotel information changed. Refresh before saving.'using errcode='40001';end if;
 before_links:=jsonb_build_object('maps_url',coalesce(s.data->>'maps_url',''),'review_url',coalesce(s.data->>'review_url',''),'website_url',coalesce(s.data->>'website_url',''));
 insert into public.whatsapp_guest_settings(property_id,tenant_id,data)values(p_property,tenant,links)
 on conflict(property_id)do update set data=whatsapp_guest_settings.data||excluded.data,version=whatsapp_guest_settings.version+1,updated_at=now()returning version into ver;
 -- Existing flat menus keep their public replies. Grouped template menus keep their current version and publication state.
 update public.whatsapp_guest_menu set data=data||links,version=case when data?'categories'then version else version+1 end,updated_at=now()where property_id=p_property;
 select coalesce(full_name,email,'Staff')into actor from public.profiles where id=auth.uid();
 insert into public.property_settings_events(tenant_id,property_id,section,actor_id,actor_name,reason,details)values(tenant,p_property,'information',auth.uid(),coalesce(actor,'Staff'),trim(p_reason),jsonb_build_object('before',before_links,'after',links));
 return ver;
end $$;
revoke all on function public.save_hotel_message_links(uuid,integer,jsonb,text)from public,anon;grant execute on function public.save_hotel_message_links(uuid,integer,jsonb,text)to authenticated;

create function public.archive_hotel_message_photo(p_property uuid,p_photo uuid)returns void language plpgsql security definer set search_path=''as $$
begin
 if not private.has_permission(p_property,'staff.manage')or not exists(select 1 from public.properties p where p.id=p_property and private.tenant_is_active(p.tenant_id))then raise exception 'Hotel administrator access required.'using errcode='42501';end if;
 update public.hotel_message_photos set archived=true where id=p_photo and property_id=p_property;
 if not found then raise exception 'Photo not found for this hotel.'using errcode='22023';end if;
end $$;
revoke all on function public.archive_hotel_message_photo(uuid,uuid)from public,anon;grant execute on function public.archive_hotel_message_photo(uuid,uuid)to authenticated;

create or replace function public.save_whatsapp_guest_menu(p_property uuid,p_version integer,p_enabled boolean,p_data jsonb)returns void
language plpgsql security definer set search_path=''as $$
declare row public.whatsapp_guest_menu;item jsonb;key text;enabled_count int;shared public.whatsapp_guest_settings;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel administration access required.'using errcode='42501';end if;
 if p_enabled is null or p_data is null or jsonb_typeof(p_data)<>'object'or pg_column_size(p_data)>120000 then raise exception 'Check the guest menu form.'using errcode='22023';end if;
 if p_data?'categories'then perform private.validate_grouped_menu(p_property,p_data,p_enabled);end if;
 perform pg_advisory_xact_lock(hashtextextended('wa-studio:'||p_property::text,0));
 perform pg_advisory_xact_lock(hashtextextended('guest-menu:'||p_property::text,0));
 select *into row from public.whatsapp_guest_menu where property_id=p_property;
 if coalesce(row.version,0)<>p_version then raise exception 'Guest menu changed. Refresh before saving.'using errcode='40001';end if;
 select *into shared from public.whatsapp_guest_settings where property_id=p_property;
 if shared.property_id is not null or p_data?'categories'then
  p_data:=p_data||jsonb_build_object('maps_url',coalesce(shared.data->>'maps_url',''),'review_url',coalesce(shared.data->>'review_url',''),'website_url',coalesce(shared.data->>'website_url',''),'photos',coalesce(row.data->'photos','[]'::jsonb));
 end if;

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
 insert into public.whatsapp_guest_settings(property_id,tenant_id,data)select p_property,p.tenant_id,jsonb_build_object('maps_url',coalesce(p_data->>'maps_url',''),'review_url',coalesce(p_data->>'review_url',''),'website_url',coalesce(p_data->>'website_url',''),'hotel_photo_url',coalesce(p_data#>>'{photos,0,url}',''))from public.properties p where p.id=p_property on conflict(property_id)do nothing;
end $$;
