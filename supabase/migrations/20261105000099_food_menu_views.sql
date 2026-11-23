create index food_menu_browse on public.menu_items(property_id,deleted_at,active,category_id,name);
create index food_variant_item on public.menu_item_variants(menu_item_id,position,id);
create function private.food_item_json(p_id uuid,p_all_sizes boolean default false)returns jsonb
language sql stable security definer set search_path=''as $$
 select jsonb_build_object('id',m.id,'version',m.version,'name',m.name,'category_id',m.category_id,'category',c.name,'price',m.price::text,'tax_rate_percent',m.tax_rate_percent::text,'description',m.description,'dietary_notes',m.dietary_notes,'prep_minutes',m.prep_minutes,'active',m.active,'deleted_at',m.deleted_at,'dietary_type',m.dietary_type,'service_scope',m.service_scope,'pricing_mode',m.pricing_mode,'image_id',m.image_id,'image_url',p.url,
 'variants',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'label',v.label,'price',v.price::text,'version',v.version,'active',v.active)order by v.position,v.id)from public.menu_item_variants v where v.menu_item_id=m.id and(p_all_sizes or v.active)),'[]'::jsonb))
 from public.menu_items m join public.menu_categories c on c.id=m.category_id left join public.food_menu_photos p on p.id=m.image_id and p.property_id=m.property_id where m.id=p_id
$$;
create function private.food_menu_page(p_property uuid,p_filters jsonb,p_kind text default null)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare query text;state text;diet text;service text;category text;page integer;size integer;total integer;items jsonb;
begin
 if p_filters is null or jsonb_typeof(p_filters)<>'object'then raise exception 'Invalid menu filters.'using errcode='22023';end if;
 query:=lower(left(trim(coalesce(p_filters->>'q','')),100));state:=coalesce(p_filters->>'state','active');diet:=coalesce(p_filters->>'diet','');service:=coalesce(p_filters->>'service','');category:=coalesce(p_filters->>'category','');
 if state not in('active','inactive','all','deleted')then state:='active';end if;
 if diet not in('veg','non_veg','egg','vegan','not_specified')then diet:='';end if;
 if service not in('restaurant','room_service','both')then service:='';end if;
 page:=case when coalesce(p_filters->>'page','')~'^[0-9]{1,6}$'then greatest(1,(p_filters->>'page')::integer)else 1 end;
 size:=case when p_kind is not null then 10 when p_filters->>'page_size'in('10','20','50')then(p_filters->>'page_size')::integer else 10 end;
 with matches as materialized(select m.id,m.name,c.name as category from public.menu_items m join public.menu_categories c on c.id=m.category_id where m.property_id=p_property
 and(case when state='deleted'then m.deleted_at is not null else m.deleted_at is null and(state='all'or m.active=(state='active'))end)
 and(query=''or strpos(lower(m.name||' '||m.description||' '||c.name||' '||m.dietary_notes),query)>0)
 and(diet=''or m.dietary_type=diet or(diet='veg'and m.dietary_type='vegan'))and(service=''or(service='both'and m.service_scope='both')or(service in('restaurant','room_service')and m.service_scope in('both',service)))
 and(category=''or m.category_id::text=category)and(p_kind is null or m.service_scope in('both',p_kind)))
 select count(*)into total from matches;
 if p_kind is null then page:=least(page,greatest(1,(total+size-1)/size));end if;
 select coalesce(jsonb_agg(private.food_item_json(x.id,p_kind is null)order by x.category,x.name,x.id),'[]'::jsonb)into items from(select m.id,m.name,c.name as category from public.menu_items m join public.menu_categories c on c.id=m.category_id where m.property_id=p_property
 and(case when state='deleted'then m.deleted_at is not null else m.deleted_at is null and(state='all'or m.active=(state='active'))end)
 and(query=''or strpos(lower(m.name||' '||m.description||' '||c.name||' '||m.dietary_notes),query)>0)
 and(diet=''or m.dietary_type=diet or(diet='veg'and m.dietary_type='vegan'))and(service=''or(service='both'and m.service_scope='both')or(service in('restaurant','room_service')and m.service_scope in('both',service)))
 and(category=''or m.category_id::text=category)and(p_kind is null or m.service_scope in('both',p_kind))order by c.name,m.name,m.id limit size offset(page-1)*size)x;
 return jsonb_build_object('items',items,'total',total,'page',page,'page_size',size,'currency',(select currency from public.properties where id=p_property),
 'categories',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name)order by c.position,c.name)from public.menu_categories c where c.property_id=p_property and(p_kind is null or exists(select 1 from public.menu_items m where m.category_id=c.id and m.active and m.deleted_at is null and m.service_scope in('both',p_kind)))),'[]'::jsonb),
 'counts',(select jsonb_build_object('active',count(*)filter(where active and deleted_at is null),'inactive',count(*)filter(where not active and deleted_at is null),'deleted',count(*)filter(where deleted_at is not null),'all',count(*)filter(where deleted_at is null))from public.menu_items where property_id=p_property));
end $$;
create function public.food_menu_workspace(p_property uuid,p_filters jsonb default '{}')returns jsonb
language plpgsql stable security definer set search_path=''as $$
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Menu management access required.'using errcode='42501';end if;
 return private.food_menu_page(p_property,p_filters);
end $$;
create function public.food_menu_item(p_property uuid,p_id uuid default null)returns jsonb
language plpgsql stable security definer set search_path=''as $$
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Menu management access required.'using errcode='42501';end if;
 return jsonb_build_object('currency',(select currency from public.properties where id=p_property),'item',(select private.food_item_json(id,true)from public.menu_items where id=p_id and property_id=p_property),'categories',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name)order by position,name)from public.menu_categories where property_id=p_property),'[]'::jsonb));
end $$;
create function public.food_menu_access(p_property uuid)returns boolean language plpgsql stable security definer set search_path=''as $$
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Menu management access required.'using errcode='42501';end if;
 perform private.staff_share(p_property);return true;
end $$;
create or replace function public.order_menu_setup(p_property uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'not permitted'using errcode='42501';end if;
 return jsonb_build_object('items',coalesce((select jsonb_agg(private.food_item_json(id,true)order by name,id)from public.menu_items where property_id=p_property),'[]'::jsonb),'categories',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name)order by position,name)from public.menu_categories where property_id=p_property),'[]'::jsonb),'currency',(select currency from public.properties where id=p_property));
end $$;
alter function public.order_setup(uuid,text,uuid)rename to order_setup_before_food_menu;
revoke all on function public.order_setup_before_food_menu(uuid,text,uuid)from public,anon,authenticated,service_role;
create function public.order_setup(p_property uuid,p_query text default '',p_reservation uuid default null)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare data jsonb;
begin
 data:=public.order_setup_before_food_menu(p_property,p_query,p_reservation);
 return data||jsonb_build_object('menu',coalesce((select jsonb_agg(private.food_item_json(id)order by name,id)from public.menu_items where property_id=p_property and active and deleted_at is null),'[]'::jsonb));
end $$;
alter function public.portal_workspace(text,jsonb)rename to portal_workspace_before_food_menu;
revoke all on function public.portal_workspace_before_food_menu(text,jsonb)from public,anon,authenticated,service_role;
create function public.portal_workspace(p_token text,p_filters jsonb default '{}')returns jsonb
language plpgsql security definer set search_path=''as $$
declare data jsonb;r public.reservations;menu jsonb;
begin
 data:=public.portal_workspace_before_food_menu(p_token,p_filters);r:=private.portal_reservation(p_token);
 menu:=private.food_menu_page(r.property_id,p_filters||jsonb_build_object('state','active','service','room_service','page',coalesce(p_filters->'menu_page','1'::jsonb)),'room_service');
 return data||jsonb_build_object('menu',menu->'items','menu_total',menu->'total','menu_page_size',10,'menu_page',menu->'page','menu_categories',menu->'categories');
end $$;
alter function public.portal_command(text,uuid,text,jsonb)rename to portal_command_before_food_menu;
revoke all on function public.portal_command_before_food_menu(text,uuid,text,jsonb)from public,anon,authenticated,service_role;
create function public.portal_command(p_token text,p_request uuid,p_action text,p_payload jsonb default '{}')returns jsonb
language plpgsql security definer set search_path=''as $$
declare r public.reservations;
begin
 if p_action='order'then
  r:=private.portal_reservation(p_token);perform pg_advisory_xact_lock(hashtextextended('portal-reservation:'||r.id::text,0));
  if not exists(select 1 from private.guest_portal_commands where reservation_id=r.id and request_id=p_request)then
   perform 1 from public.properties where id=r.property_id for share;perform 1 from public.reservations where id=r.id for update;
   perform private.billing_lock(r.id);perform *from private.food_order_lines(r.property_id,'room_service',p_payload->'items',true);
  end if;
 end if;
 return public.portal_command_before_food_menu(p_token,p_request,p_action,p_payload);
end $$;
revoke all on function public.food_menu_workspace(uuid,jsonb),public.food_menu_item(uuid,uuid),public.food_menu_access(uuid),public.order_setup(uuid,text,uuid)from public,anon;
grant execute on function public.food_menu_workspace(uuid,jsonb),public.food_menu_item(uuid,uuid),public.food_menu_access(uuid),public.order_setup(uuid,text,uuid)to authenticated;
revoke all on function public.portal_workspace(text,jsonb),public.portal_command(text,uuid,text,jsonb)from public;
grant execute on function public.portal_workspace(text,jsonb),public.portal_command(text,uuid,text,jsonb)to anon,authenticated;
revoke all on function private.food_item_json(uuid,boolean),private.food_menu_page(uuid,jsonb,text)from public,anon,authenticated,service_role;
