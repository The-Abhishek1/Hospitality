-- Imports create new items through the same catalog writer as the item form.
-- A batch is atomic and retries return its saved result without creating duplicates.
create table private.food_menu_import_commands(
 property_id uuid not null references public.properties(id)on delete cascade,request_id uuid not null,
 actor_id uuid,payload jsonb not null,result jsonb not null,created_at timestamptz not null default now(),
 primary key(property_id,request_id)
);
revoke all on private.food_menu_import_commands from public,anon,authenticated,service_role;
create function private.food_menu_import_check(p_property uuid,p_items jsonb)returns void language plpgsql stable security definer set search_path=''as $$begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Menu management access required.'using errcode='42501';end if;
 if jsonb_typeof(p_items)is distinct from'array'or jsonb_array_length(p_items)not between 1 and 200 or pg_column_size(p_items)>700000 then raise exception 'Import 1–200 items and up to 500 spreadsheet rows.'using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements(p_items)x where jsonb_typeof(x->'details')is distinct from'object'or coalesce(x->>'row','')!~'^[0-9]{1,3}$'or length(trim(coalesce(x#>>'{details,name}','')))not between 2 and 120)then raise exception 'Check the item names and spreadsheet row numbers.'using errcode='22023';end if;
 if(select count(distinct lower(trim(x#>>'{details,name}')))from jsonb_array_elements(p_items)x)<>jsonb_array_length(p_items)then raise exception 'Each item must appear once in the import, with its sizes grouped together.'using errcode='22023';end if;
end $$;
create function public.food_menu_import_preview(p_property uuid,p_items jsonb)returns jsonb language plpgsql stable security definer set search_path=''as $$declare rows jsonb;begin
 perform private.food_menu_import_check(p_property,p_items);
 select jsonb_agg(jsonb_build_object('row',(x->>'row')::integer,'name',x#>>'{details,name}','category',x#>>'{details,category}','price',case when x#>>'{details,pricing_mode}'='sizes'then(select min((v->>'price')::numeric)::text from jsonb_array_elements(x#>'{details,variants}')v)else x#>>'{details,price}'end,'sizes',coalesce(jsonb_array_length(x#>'{details,variants}'),0),'food_type',x#>>'{details,dietary_type}','served_in',x#>>'{details,service_scope}','available',x#>'{details,active}','state',case when m.id is null then'new'when m.deleted_at is not null then'deleted'else'existing'end)order by n)into rows
 from jsonb_array_elements(p_items)with ordinality t(x,n)left join lateral(select id,deleted_at from public.menu_items where property_id=p_property and lower(trim(name))=lower(trim(x#>>'{details,name}'))order by id limit 1)m on true;
 return jsonb_build_object('rows',rows,'new_count',(select count(*)from jsonb_array_elements(rows)x where x->>'state'='new'),'existing_count',(select count(*)from jsonb_array_elements(rows)x where x->>'state'<>'new'));
end $$;
create function public.food_menu_import(p_property uuid,p_request uuid,p_items jsonb,p_duplicates text default 'skip')returns jsonb language plpgsql security definer set search_path=''as $$
declare cmd private.food_menu_import_commands;payload jsonb;result jsonb;x jsonb;existing uuid;created integer:=0;skipped integer:=0;ids jsonb:='[]';id uuid;begin
 perform private.food_menu_import_check(p_property,p_items);
 if p_request is null or p_duplicates is null or p_duplicates not in('skip','error')then raise exception 'Choose how to handle existing items and preview the file again.'using errcode='22023';end if;
 payload:=jsonb_build_object('items',p_items,'duplicates',p_duplicates);
 perform pg_advisory_xact_lock(hashtextextended('menu-import:'||p_property::text||p_request::text,0));
 select *into cmd from private.food_menu_import_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.actor_id is distinct from auth.uid()or cmd.payload is distinct from payload then raise exception 'This import request was already used for a different file or option. Preview again.'using errcode='40001';end if;return cmd.result;end if;
 perform pg_advisory_xact_lock(hashtextextended('order-menu:'||p_property::text,0));
 perform private.staff_share(p_property);
 if not exists(select 1 from public.properties prop where prop.id=p_property and prop.archived_at is null)then raise exception 'This hotel is closed. Menu imports are unavailable.'using errcode='22023';end if;
 for x in select value from jsonb_array_elements(p_items)loop
  select m.id into existing from public.menu_items m where m.property_id=p_property and lower(trim(m.name))=lower(trim(x#>>'{details,name}'))limit 1;
  if existing is not null then
   if p_duplicates='error'then raise exception 'Row %: “%” already exists, including deleted items. No items were imported.',x->>'row',x#>>'{details,name}'using errcode='23505';end if;
   skipped:=skipped+1;continue;
  end if;
  begin id:=public.order_menu_save(p_property,gen_random_uuid(),null,null,x->'details');
  exception when sqlstate '22023'or sqlstate '23505'or sqlstate '22003'or sqlstate '22P02'then raise exception 'Row %: %. No items were imported.',x->>'row',sqlerrm using errcode='22023';end;
  created:=created+1;ids:=ids||jsonb_build_array(id);
 end loop;
 result:=jsonb_build_object('created',created,'skipped',skipped,'ids',ids);
 insert into private.food_menu_import_commands(property_id,request_id,actor_id,payload,result)values(p_property,p_request,auth.uid(),payload,result);
 return result;
end $$;
revoke all on function private.food_menu_import_check(uuid,jsonb)from public,anon,authenticated,service_role;
revoke all on function public.food_menu_import_preview(uuid,jsonb),public.food_menu_import(uuid,uuid,jsonb,text)from public,anon;
grant execute on function public.food_menu_import_preview(uuid,jsonb),public.food_menu_import(uuid,uuid,jsonb,text)to authenticated;
