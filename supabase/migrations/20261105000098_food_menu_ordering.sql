-- One selection/pricing path for staff, guests and legacy order APIs.
create or replace function private.food_order_lines(p_property uuid,p_kind text,p_items jsonb,p_versions boolean default false)
returns table(menu_item_id uuid,variant_id uuid,variant_label text,name text,price numeric,tax_rate_percent numeric,quantity integer,prep_minutes integer)
language plpgsql security definer set search_path=''as $$
declare x jsonb;m public.menu_items;v public.menu_item_variants;vid uuid;
begin
 if p_kind is null or p_kind not in('restaurant','room_service')then raise exception 'Choose restaurant or room service.'using errcode='22023';end if;
 if p_items is null or jsonb_typeof(p_items)<>'array'or jsonb_array_length(p_items)not between 1 and 30 then raise exception 'Choose 1–30 different menu items or sizes.'using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements(p_items)i where coalesce(i->>'menu_item_id','')!~'^[a-fA-F0-9-]{36}$'or case when coalesce(i->>'quantity','')~'^[1-9][0-9]?$'then(i->>'quantity')::integer>50 else true end)then raise exception 'Choose valid menu items and quantities of 1–50.'using errcode='22023';end if;
 if(select count(distinct(i->>'menu_item_id')||':'||coalesce(i->>'variant_id',''))from jsonb_array_elements(p_items)i)<>jsonb_array_length(p_items)then raise exception 'Each item and size may appear once in the cart.'using errcode='22023';end if;
 perform mi.id from public.menu_items mi join jsonb_to_recordset(p_items)as j(menu_item_id uuid)on j.menu_item_id=mi.id where mi.property_id=p_property order by mi.id for share of mi;
 perform mv.id from public.menu_item_variants mv join jsonb_to_recordset(p_items)as j(variant_id uuid)on j.variant_id=mv.id where mv.property_id=p_property order by mv.id for share of mv;
 for x in select *from jsonb_array_elements(p_items)loop
  select *into m from public.menu_items mi where mi.id=(x->>'menu_item_id')::uuid and mi.property_id=p_property;
  if not p_versions and(m.id is null or not m.active or m.deleted_at is not null)then raise exception 'Unknown or unavailable menu item.'using errcode='22023';end if;
  if m.id is null or not m.active or m.deleted_at is not null or(p_versions and m.version is distinct from nullif(x->>'version','')::integer)then raise exception 'The menu changed. Refresh and review prices before placing this order.'using errcode='40001';end if;
  if m.service_scope not in('both',p_kind)then raise exception 'This item is not available for the selected restaurant or room-service destination.'using errcode='22023';end if;
  vid:=nullif(x->>'variant_id','')::uuid;v:=null;
  if m.pricing_mode='sizes'then
   select *into v from public.menu_item_variants mv where mv.id=vid and mv.menu_item_id=m.id and mv.property_id=p_property and mv.active;
   if v.id is null or(p_versions and v.version is distinct from nullif(x->>'variant_version','')::integer)then raise exception 'Choose an available size. Its price may have changed; refresh the menu.'using errcode='40001';end if;
  elsif vid is not null then raise exception 'This item uses one price. Refresh the menu.'using errcode='40001';end if;
  return query select m.id,v.id,v.label,m.name||case when v.id is not null then' · '||v.label else''end,coalesce(v.price,m.price),m.tax_rate_percent,(x->>'quantity')::integer,m.prep_minutes;
 end loop;
end $$;

create or replace function private.place_order_core(p_property uuid,p_kind text,p_items jsonb,p_reservation uuid,p_table text,p_notes text,p_actor uuid)returns uuid
language plpgsql security definer set search_path=''as $$
declare tenant uuid;r public.reservations;unit uuid;created_id uuid;sub numeric:=0;tax_amount numeric:=0;rec record;target integer;bill public.folios;
begin
 select tenant_id into tenant from public.properties where id=p_property for share;perform private.staff_share(p_property);
 if tenant is null then raise exception 'unknown property'using errcode='22023';end if;
 if length(coalesce(p_table,''))>40 or length(coalesce(p_notes,''))>2000 then raise exception 'Keep table labels under 40 characters and instructions under 2000.'using errcode='22023';end if;
 if p_reservation is not null then
  select *into r from public.reservations where id=p_reservation and property_id=p_property for update;
  if not found or r.status<>'checked_in'then raise exception 'Choose an in-house guest for room charges.'using errcode='22023';end if;
  bill:=private.billing_lock(r.id);if bill.status<>'open'then raise exception 'The room bill is closed. Contact reception.'using errcode='22023';end if;
  select unit_id into unit from public.unit_holds where reservation_id=r.id and active order by created_at desc limit 1;
 elsif p_kind='room_service'then raise exception 'Room service requires an in-house stay.'using errcode='22023';end if;
 -- Validate and lock every selected menu/size before inserting the order.
 perform *from private.food_order_lines(p_property,p_kind,p_items,false);
 insert into public.orders(tenant_id,property_id,kind,reservation_id,unit_id,table_label,notes,placed_by,source)
 values(tenant,p_property,p_kind,p_reservation,unit,nullif(trim(p_table),''),nullif(trim(p_notes),''),p_actor,case when p_actor is null then'guest_portal'else'staff'end)returning id into created_id;
 for rec in select *from private.food_order_lines(p_property,p_kind,p_items,false)loop
  insert into public.order_items(tenant_id,property_id,order_id,menu_item_id,variant_id,variant_label,name_snapshot,unit_price,tax_rate_percent,quantity)
  values(tenant,p_property,created_id,rec.menu_item_id,rec.variant_id,rec.variant_label,rec.name,rec.price,rec.tax_rate_percent,rec.quantity);
  sub:=sub+rec.price*rec.quantity;tax_amount:=tax_amount+round(rec.price*rec.quantity*rec.tax_rate_percent/100,2);target:=greatest(target,rec.prep_minutes);
 end loop;
 if sub+tax_amount>9999999999.99 then raise exception 'Order total exceeds the supported amount. Split it into smaller orders.'using errcode='22023';end if;
 update public.orders set subtotal=sub,tax=tax_amount,total=sub+tax_amount,due_at=case when target is not null then now()+make_interval(mins=>target)end where id=created_id;
 insert into public.kitchen_events(tenant_id,property_id,order_id,event_type,actor_id)values(tenant,p_property,created_id,'placed',p_actor);return created_id;
end $$;

create or replace function public.orders_create(p_property uuid,p_request uuid,p_details jsonb)returns uuid
language plpgsql security definer set search_path=''as $$
declare cmd public.order_commands;created_id uuid;items jsonb;total numeric;mins integer;rid uuid;bill public.folios;
begin
 if not private.has_permission(p_property,'orders.place')then raise exception 'not permitted'using errcode='42501';end if;
 if p_request is null or p_details is null or jsonb_typeof(p_details)<>'object'or pg_column_size(p_details)>24000 then raise exception 'Reload the order form.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('orders-command:'||p_property::text||p_request::text,0));
 select *into cmd from public.order_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.action<>'create'or cmd.payload is distinct from p_details then raise exception 'Request ID already used for different order details.'using errcode='22023';end if;return cmd.result_id;end if;
 perform 1 from public.properties where id=p_property for share;
 if p_details?'expected_currency'and(p_details->>'expected_currency')is distinct from(select currency from public.properties where id=p_property)then raise exception 'The hotel currency changed. Refresh and review the order total.'using errcode='40001';end if;
 rid:=nullif(p_details->>'reservation_id','')::uuid;
 if rid is not null then
  perform 1 from public.reservations where id=rid and property_id=p_property and status='checked_in'for update;
  if not found then raise exception 'Choose an in-house guest for room charges.'using errcode='22023';end if;
  bill:=private.billing_lock(rid);if bill.status<>'open'then raise exception 'The room bill is closed. Contact reception.'using errcode='22023';end if;
 end if;
 items:=p_details->'items';select sum(l.price*l.quantity+round(l.price*l.quantity*l.tax_rate_percent/100,2))into total from private.food_order_lines(p_property,p_details->>'kind',items,true)l;
 if p_details->>'quote'is null or(p_details->>'quote')::numeric is distinct from total then raise exception 'Order prices changed. Review the cart total before placing it.'using errcode='40001';end if;
 if coalesce(p_details->>'priority','normal')not in('normal','high','urgent')then raise exception 'Choose a valid priority.'using errcode='22023';end if;
 mins:=nullif(p_details->>'target_minutes','')::integer;if mins is not null and mins not between 1 and 1440 then raise exception 'Response target must be 1–1440 minutes.'using errcode='22023';end if;
 created_id:=private.place_order_core(p_property,p_details->>'kind',items,rid,p_details->>'table',p_details->>'notes',auth.uid());
 update public.orders set priority=coalesce(p_details->>'priority','normal'),due_at=case when mins is not null then now()+make_interval(mins=>mins)else due_at end where id=created_id;
 insert into public.order_commands(tenant_id,property_id,request_id,order_id,action,payload,result_id,actor_id)select tenant_id,p_property,p_request,id,'create',p_details,id,auth.uid()from public.orders where id=created_id;return created_id;
end $$;
revoke all on function private.food_order_lines(uuid,text,jsonb,boolean)from public,anon,authenticated,service_role;
