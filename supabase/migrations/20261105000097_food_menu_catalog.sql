-- Food categories, dietary classification and service destinations are independent.
alter table public.menu_items
 add column dietary_type text not null default 'not_specified' check(dietary_type in('veg','non_veg','egg','vegan','not_specified')),
 add column service_scope text not null default 'both' check(service_scope in('both','restaurant','room_service')),
 add column pricing_mode text not null default 'single' check(pricing_mode in('single','sizes')),
 add column deleted_at timestamptz,
 add column image_id uuid;
create table public.food_menu_photos(
 id uuid primary key default gen_random_uuid(),property_id uuid not null references public.properties(id)on delete cascade,
 storage_path text not null unique,url text not null,mime_type text not null,created_at timestamptz not null default now(),unique(id,property_id)
);
alter table public.food_menu_photos enable row level security;
revoke all on public.food_menu_photos from public,anon,authenticated;
grant all on public.food_menu_photos to service_role;
alter table public.menu_items add foreign key(image_id,property_id)references public.food_menu_photos(id,property_id);
create table public.menu_item_variants(
 id uuid primary key default gen_random_uuid(),menu_item_id uuid not null,property_id uuid not null,
 label text not null check(length(trim(label))between 1 and 40),price numeric(12,2)not null check(price>=0),
 active boolean not null default true,position integer not null default 0,version integer not null default 1,
 unique(id,property_id),foreign key(menu_item_id,property_id)references public.menu_items(id,property_id)
);
create unique index menu_variant_label on public.menu_item_variants(menu_item_id,lower(trim(label)))where active;
alter table public.menu_item_variants enable row level security;
revoke all on public.menu_item_variants from public,anon,authenticated;
grant all on public.menu_item_variants to service_role;
create function private.food_variant_version()returns trigger language plpgsql set search_path=''as $$begin new.version:=old.version+1;return new;end $$;
create trigger food_variant_version before update on public.menu_item_variants for each row execute function private.food_variant_version();
create trigger archived_property_write before insert or update or delete on public.menu_item_variants for each row execute function private.guard_archived_property_write();
create trigger archived_property_write before insert or update or delete on public.food_menu_photos for each row execute function private.guard_archived_property_write();
alter table public.order_items add column variant_id uuid,add column variant_label text;
alter table public.order_items add foreign key(variant_id,property_id)references public.menu_item_variants(id,property_id);
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)values('food-menu-photos','food-menu-photos',true,4194304,array['image/jpeg','image/png','image/webp'])on conflict(id)do nothing;

create or replace function public.order_menu_save(p_property uuid,p_request uuid,p_id uuid,p_version integer,p_details jsonb)returns uuid
language plpgsql security definer set search_path=''as $$
declare cmd public.order_commands;item public.menu_items;tenant uuid;category uuid;result_id uuid;new_price numeric;new_tax numeric;prep integer;
 diet text;scope text;mode text;photo uuid;sizes jsonb;v jsonb;position integer:=0;keep_ids uuid[]:='{}';
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'not permitted'using errcode='42501';end if;
 if p_request is null or p_details is null or jsonb_typeof(p_details)<>'object'or pg_column_size(p_details)>24000 then raise exception 'Reload this menu form.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('orders-command:'||p_property::text||p_request::text,0));
 select *into cmd from public.order_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.action<>'menu'or cmd.menu_id is distinct from coalesce(p_id,cmd.result_id)or cmd.payload is distinct from p_details then raise exception 'Request ID already used for different menu details.'using errcode='22023';end if;return cmd.result_id;end if;
 perform pg_advisory_xact_lock(hashtextextended('order-menu:'||p_property::text,0));
 select tenant_id into tenant from public.properties where id=p_property for share;perform private.staff_share(p_property);
 if p_id is not null then
  select *into item from public.menu_items where id=p_id and property_id=p_property for update;
  if not found or item.deleted_at is not null then raise exception 'Menu item is unavailable or deleted. Restore it before editing.'using errcode='22023';end if;
  if item.version is distinct from p_version then raise exception 'This menu item changed. Refresh before saving.'using errcode='40001';end if;
 end if;
 if length(trim(coalesce(p_details->>'name','')))not between 2 and 120 or length(trim(coalesce(p_details->>'category','')))not between 2 and 80 or length(coalesce(p_details->>'description',''))>800 or length(coalesce(p_details->>'dietary_notes',''))>200 then raise exception 'Check item name, category, description and dietary notes.'using errcode='22023';end if;
 diet:=coalesce(p_details->>'dietary_type',item.dietary_type,'not_specified');scope:=coalesce(p_details->>'service_scope',item.service_scope,'both');mode:=coalesce(p_details->>'pricing_mode',item.pricing_mode,'single');
 if diet not in('veg','non_veg','egg','vegan','not_specified')or scope not in('both','restaurant','room_service')or mode not in('single','sizes')then raise exception 'Choose a food type, service destination and pricing mode.'using errcode='22023';end if;
 photo:=case when p_details?'image_id'then nullif(p_details->>'image_id','')::uuid else item.image_id end;
 if photo is not null and not exists(select 1 from public.food_menu_photos where id=photo and property_id=p_property)then raise exception 'Choose a food photo uploaded to this hotel.'using errcode='22023';end if;
 if coalesce(p_details->>'price','')!~'^[0-9]{1,10}(\.[0-9]{1,2})?$'or coalesce(p_details->>'tax','')!~'^[0-9]{1,3}(\.[0-9]{1,2})?$'then raise exception 'Enter non-negative prices and tax with up to two decimals.'using errcode='22023';end if;
 new_price:=(p_details->>'price')::numeric;new_tax:=(p_details->>'tax')::numeric;
 if new_tax>100 then raise exception 'Tax must be 0–100 percent.'using errcode='22023';end if;
 prep:=nullif(p_details->>'prep_minutes','')::integer;if prep is not null and prep not between 1 and 240 then raise exception 'Preparation targets must be 1–240 minutes.'using errcode='22023';end if;
 sizes:=p_details->'variants';
 if mode='sizes'and(jsonb_typeof(sizes)is distinct from 'array'or jsonb_array_length(sizes)not between 1 and 12)then raise exception 'Add 1–12 sizes with their prices.'using errcode='22023';end if;
 if mode='sizes'then
  for v in select *from jsonb_array_elements(sizes)loop
   if coalesce(v->>'id','')!~'^[a-fA-F0-9-]{36}$'or length(trim(coalesce(v->>'label','')))not between 1 and 40 or coalesce(v->>'price','')!~'^[0-9]{1,10}(\.[0-9]{1,2})?$'then raise exception 'Each size needs a valid ID, name and non-negative price.'using errcode='22023';end if;
   if(v->>'id')::uuid=any(keep_ids)or exists(select 1 from public.menu_item_variants where id=(v->>'id')::uuid and(menu_item_id is distinct from p_id or property_id<>p_property))then raise exception 'A size belongs to another menu item or appears twice.'using errcode='22023';end if;
   if exists(select 1 from public.menu_item_variants where id=(v->>'id')::uuid and version is distinct from nullif(v->>'version','')::integer)then raise exception 'A size changed. Refresh before saving.'using errcode='40001';end if;
   keep_ids:=array_append(keep_ids,(v->>'id')::uuid);
  end loop;
  if(select count(distinct lower(trim(x->>'label')))from jsonb_array_elements(sizes)x)<>jsonb_array_length(sizes)then raise exception 'Use a different name for each size.'using errcode='22023';end if;
  select min((x->>'price')::numeric)into new_price from jsonb_array_elements(sizes)x;
 end if;
 if exists(select 1 from public.menu_items where property_id=p_property and lower(trim(name))=lower(trim(p_details->>'name'))and id is distinct from p_id)then raise exception 'An item with this name already exists. Check deleted items if necessary.'using errcode='23505';end if;
 select id into category from public.menu_categories where property_id=p_property and lower(trim(name))=lower(trim(p_details->>'category'))limit 1;
 if category is null then insert into public.menu_categories(tenant_id,property_id,name)values(tenant,p_property,trim(p_details->>'category'))returning id into category;end if;
 if p_id is null then
  insert into public.menu_items(tenant_id,property_id,category_id,name,price,tax_rate_percent,description,dietary_notes,prep_minutes,active,dietary_type,service_scope,pricing_mode,image_id)
  values(tenant,p_property,category,trim(p_details->>'name'),new_price,new_tax,coalesce(p_details->>'description',''),coalesce(p_details->>'dietary_notes',''),prep,coalesce((p_details->>'active')::boolean,true),diet,scope,mode,photo)returning id into result_id;
 else
  update public.menu_items set category_id=category,name=trim(p_details->>'name'),price=new_price,tax_rate_percent=new_tax,description=coalesce(p_details->>'description',''),dietary_notes=coalesce(p_details->>'dietary_notes',''),prep_minutes=prep,active=coalesce((p_details->>'active')::boolean,true),dietary_type=diet,service_scope=scope,pricing_mode=mode,image_id=photo where id=p_id returning id into result_id;
 end if;
 if p_details?'variants'or mode='single'then
  update public.menu_item_variants set active=false where menu_item_id=result_id and active;
  if mode='sizes'then
   for v in select *from jsonb_array_elements(sizes)loop
    insert into public.menu_item_variants(id,menu_item_id,property_id,label,price,position,active)values((v->>'id')::uuid,result_id,p_property,trim(v->>'label'),(v->>'price')::numeric,position,true)
    on conflict(id)do update set label=excluded.label,price=excluded.price,position=excluded.position,active=true;
    position:=position+1;
   end loop;
  end if;
 end if;
 insert into public.order_commands(tenant_id,property_id,request_id,menu_id,action,payload,result_id,actor_id)values(tenant,p_property,p_request,result_id,'menu',p_details,result_id,auth.uid());return result_id;
end $$;

create function public.order_menu_lifecycle(p_property uuid,p_id uuid,p_version integer,p_request uuid,p_action text)returns void
language plpgsql security definer set search_path=''as $$
declare item public.menu_items;cmd public.order_commands;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Menu management access required.'using errcode='42501';end if;
 if p_action not in('delete','restore')or p_action is null or p_request is null then raise exception 'Choose delete or restore.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('orders-command:'||p_property::text||p_request::text,0));
 select *into cmd from public.order_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.action<>'menu_'||p_action or cmd.menu_id<>p_id then raise exception 'This request was already used.'using errcode='22023';end if;return;end if;
 perform pg_advisory_xact_lock(hashtextextended('order-menu:'||p_property::text,0));perform private.staff_share(p_property);
 select *into item from public.menu_items where id=p_id and property_id=p_property for update;
 if item.id is null then raise exception 'Menu item not found.'using errcode='22023';end if;
 if item.version is distinct from p_version then raise exception 'The menu item changed. Refresh before continuing.'using errcode='40001';end if;
 if(p_action='delete'and item.deleted_at is not null)or(p_action='restore'and item.deleted_at is null)then raise exception 'This item is already in that state.'using errcode='22023';end if;
 update public.menu_items set deleted_at=case when p_action='delete'then now()end,active=false where id=p_id;
 insert into public.order_commands(tenant_id,property_id,request_id,menu_id,action,payload,result_id,actor_id)values(item.tenant_id,p_property,p_request,p_id,'menu_'||p_action,jsonb_build_object('version',p_version),p_id,auth.uid());
end $$;
revoke all on function public.order_menu_lifecycle(uuid,uuid,integer,uuid,text)from public,anon;
grant execute on function public.order_menu_lifecycle(uuid,uuid,integer,uuid,text)to authenticated;
revoke all on function private.food_variant_version()from public,anon,authenticated,service_role;
