-- A web booking/order must still use the currency shown in its review form.
create function public.frontdesk_create_reviewed(p_property uuid,p_currency text,p_request uuid,p_guest_name text,p_phone text,p_email text,p_type uuid,p_in date,p_out date,p_adults integer,p_children integer,p_rate uuid default null,p_unit uuid default null,p_notes text default '',p_source text default 'direct',p_quote numeric default null)returns uuid language plpgsql security definer set search_path=''as $$
declare current_currency text;
begin
 if not private.has_permission(p_property,'reservations.write')then raise exception 'not permitted'using errcode='42501';end if;
 select currency into current_currency from public.properties where id=p_property for share;
 if current_currency is distinct from p_currency then raise exception 'The hotel currency changed. Refresh and review the booking quote.'using errcode='40001';end if;
 return public.frontdesk_create(p_property,p_request,p_guest_name,p_phone,p_email,p_type,p_in,p_out,p_adults,p_children,p_rate,p_unit,p_notes,p_source,p_quote);
end $$;
revoke all on function public.frontdesk_create_reviewed(uuid,text,uuid,text,text,text,uuid,date,date,integer,integer,uuid,uuid,text,text,numeric)from public,anon;
grant execute on function public.frontdesk_create_reviewed(uuid,text,uuid,text,text,text,uuid,date,date,integer,integer,uuid,uuid,text,text,numeric)to authenticated;

create or replace function public.orders_create(p_property uuid,p_request uuid,p_details jsonb)returns uuid language plpgsql security definer set search_path=''as $$
declare cmd public.order_commands;created_id uuid;items jsonb;total numeric;count_items integer;mins integer;
begin
 if not private.has_permission(p_property,'orders.place')then raise exception 'not permitted'using errcode='42501';end if;
 if p_request is null or p_details is null or jsonb_typeof(p_details)<>'object'then raise exception 'Reload the order form.'using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('orders-command:'||p_property::text||p_request::text,0));
 select * into cmd from public.order_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.action<>'create'or cmd.payload is distinct from p_details then raise exception 'Request ID already used for different order details.'using errcode='22023';end if;return cmd.result_id;end if;
 perform 1 from public.properties where id=p_property for share;
 if p_details?'expected_currency'and(p_details->>'expected_currency')is distinct from(select currency from public.properties where id=p_property)then raise exception 'The hotel currency changed. Refresh and review the order total.'using errcode='40001';end if;
 items:=p_details->'items';if items is null or jsonb_typeof(items)<>'array'or jsonb_array_length(items)not between 1 and 30 then raise exception 'Choose 1–30 menu items.'using errcode='22023';end if;
 perform mi.id from public.menu_items mi join jsonb_to_recordset(items)as x(menu_item_id uuid,quantity integer,version integer)on mi.id=x.menu_item_id where mi.property_id=p_property order by mi.id for share of mi;
 if exists(select 1 from jsonb_to_recordset(items)as x(menu_item_id uuid,quantity integer,version integer)left join public.menu_items mi on mi.id=x.menu_item_id and mi.property_id=p_property where mi.id is null or not mi.active or mi.version is distinct from x.version)then raise exception 'The menu changed. Refresh and review prices before placing this order.'using errcode='40001';end if;
 select sum(mi.price*x.quantity+round(mi.price*x.quantity*mi.tax_rate_percent/100,2))into total from jsonb_to_recordset(items)as x(menu_item_id uuid,quantity integer)join public.menu_items mi on mi.id=x.menu_item_id and mi.property_id=p_property;
 if p_details->>'quote' is null or(p_details->>'quote')::numeric is distinct from total then raise exception 'Order prices changed. Review the cart total before placing it.'using errcode='40001';end if;
 if coalesce(p_details->>'priority','normal')not in('normal','high','urgent')then raise exception 'Choose a valid priority.'using errcode='22023';end if;
 mins:=nullif(p_details->>'target_minutes','')::integer;if mins is not null and mins not between 1 and 1440 then raise exception 'Response target must be 1–1440 minutes.'using errcode='22023';end if;
 created_id:=private.place_order_core(p_property,p_details->>'kind',items,nullif(p_details->>'reservation_id','')::uuid,p_details->>'table',p_details->>'notes',auth.uid());
 update public.orders set priority=coalesce(p_details->>'priority','normal'),due_at=case when mins is not null then now()+make_interval(mins=>mins)else due_at end where id=created_id;
 insert into public.order_commands(tenant_id,property_id,request_id,order_id,action,payload,result_id,actor_id)select tenant_id,p_property,p_request,id,'create',p_details,id,auth.uid()from public.orders where id=created_id;return created_id;
end $$;
