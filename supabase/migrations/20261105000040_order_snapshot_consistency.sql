-- Unambiguous line-tax accumulation and bounded order totals.
create or replace function private.place_order_core(p_property uuid,p_kind text,p_items jsonb,p_reservation uuid,p_table text,p_notes text,p_actor uuid)returns uuid language plpgsql security definer set search_path=''as $$
declare tenant uuid;r public.reservations;unit uuid;created_id uuid;sub numeric:=0;tax_amount numeric:=0;count_items integer:=0;rec record;target integer;
begin
 select tenant_id into tenant from public.properties where id=p_property;if tenant is null then raise exception 'unknown property'using errcode='22023';end if;
 if p_kind is null or p_kind not in('restaurant','room_service')then raise exception 'Choose restaurant or room service.'using errcode='22023';end if;
 if p_items is null or jsonb_typeof(p_items)<>'array'or jsonb_array_length(p_items)not between 1 and 30 then raise exception 'Choose 1–30 different menu items.'using errcode='22023';end if;
 if length(coalesce(p_table,''))>40 or length(coalesce(p_notes,''))>2000 then raise exception 'Keep table labels under 40 characters and instructions under 2000.'using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements(p_items)x where case when coalesce(x->>'quantity','')~'^[1-9][0-9]?$'then(x->>'quantity')::integer not between 1 and 50 else true end)then raise exception 'Use quantities of 1–50.'using errcode='22023';end if;
 if(select count(distinct x->>'menu_item_id')from jsonb_array_elements(p_items)x)<>jsonb_array_length(p_items)then raise exception 'Each menu item may appear once in the cart.'using errcode='22023';end if;
 if p_reservation is not null then
 select * into r from public.reservations where id=p_reservation and property_id=p_property for update;if not found or r.status<>'checked_in'then raise exception 'Choose an in-house guest for room charges.'using errcode='22023';end if;
 select unit_id into unit from public.unit_holds where reservation_id=r.id and active order by created_at desc limit 1;
 elsif p_kind='room_service'then raise exception 'Room service requires an in-house stay.'using errcode='22023';end if;
 -- Stable snapshots: menu edits wait until the order has copied its prices and taxes.
 perform mi.id from public.menu_items mi join jsonb_to_recordset(p_items)as x(menu_item_id uuid,quantity integer)on mi.id=x.menu_item_id where mi.property_id=p_property and mi.active order by mi.id for share of mi;
 insert into public.orders(tenant_id,property_id,kind,reservation_id,unit_id,table_label,notes,placed_by,source)values(tenant,p_property,p_kind,p_reservation,unit,nullif(trim(p_table),''),nullif(trim(p_notes),''),p_actor,case when p_actor is null then 'guest_portal'else 'staff'end)returning id into created_id;
 for rec in select mi.*,x.quantity from public.menu_items mi join jsonb_to_recordset(p_items)as x(menu_item_id uuid,quantity integer)on mi.id=x.menu_item_id where mi.property_id=p_property and mi.active order by mi.id loop
 insert into public.order_items(tenant_id,property_id,order_id,menu_item_id,name_snapshot,unit_price,tax_rate_percent,quantity)values(tenant,p_property,created_id,rec.id,rec.name,rec.price,rec.tax_rate_percent,rec.quantity);
 sub:=sub+rec.price*rec.quantity;tax_amount:=tax_amount+round(rec.price*rec.quantity*rec.tax_rate_percent/100,2);count_items:=count_items+1;target:=greatest(target,rec.prep_minutes);end loop;
 if sub+tax_amount>9999999999.99 then raise exception 'Order total exceeds the supported amount. Split it into smaller orders.'using errcode='22023';end if;
 if count_items<>jsonb_array_length(p_items)then raise exception 'A menu item is unavailable. Review the menu and try again.'using errcode='22023';end if;
 update public.orders set subtotal=sub,tax=tax_amount,total=sub+tax_amount,due_at=case when target is not null then now()+make_interval(mins=>target)end where id=created_id;
 insert into public.kitchen_events(tenant_id,property_id,order_id,event_type,actor_id)values(tenant,p_property,created_id,'placed',p_actor);return created_id;
end $$;
-- Recover stage times from recorded events, without guessing missing timestamps.
update public.orders o set
 preparing_at=(select min(created_at)from public.kitchen_events where order_id=o.id and event_type='preparing'),
 ready_at=(select min(created_at)from public.kitchen_events where order_id=o.id and event_type='ready'),
 served_at=(select min(created_at)from public.kitchen_events where order_id=o.id and event_type='served'),
 cancelled_at=(select min(created_at)from public.kitchen_events where order_id=o.id and event_type='cancelled')
 where exists(select 1 from public.kitchen_events where order_id=o.id and event_type in('preparing','ready','served','cancelled'));
