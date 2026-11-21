create function private.order_rows(p_property uuid)returns table(id uuid,version integer,kind text,status text,priority text,source text,table_label text,notes text,reservation_id uuid,unit_id uuid,room text,current_room text,guest_name text,subtotal numeric,tax numeric,total numeric,due_at timestamptz,created_at timestamptz,preparing_at timestamptz,ready_at timestamptz,served_at timestamptz,cancelled_at timestamptz,item_count bigint,items jsonb)
language sql stable security definer set search_path=''as $$
 select o.id,o.version,o.kind,o.status,o.priority,o.source,o.table_label,o.notes,o.reservation_id,o.unit_id,u.name,
 (select room.name from public.unit_holds h join public.accommodation_units room on room.id=h.unit_id where h.reservation_id=o.reservation_id order by h.active desc,h.created_at desc limit 1),
 case when private.has_permission(p_property,'reservations.read')then g.full_name end,o.subtotal,o.tax,o.total,o.due_at,o.created_at,o.preparing_at,o.ready_at,o.served_at,o.cancelled_at,
 (select sum(quantity)::bigint from public.order_items where order_id=o.id),
 coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'name',i.name_snapshot,'quantity',i.quantity,'unit_price',i.unit_price,'tax_rate_percent',i.tax_rate_percent,'subtotal',i.unit_price*i.quantity,'tax',round(i.unit_price*i.quantity*i.tax_rate_percent/100,2),'total',i.unit_price*i.quantity+round(i.unit_price*i.quantity*i.tax_rate_percent/100,2))order by i.name_snapshot,i.id)from public.order_items i where i.order_id=o.id),'[]'::jsonb)
 from public.orders o left join public.accommodation_units u on u.id=o.unit_id left join public.reservations r on r.id=o.reservation_id left join public.guests g on g.id=r.guest_id where o.property_id=p_property and private.order_access(p_property)
$$;
revoke all on function private.order_rows(uuid)from public,anon,authenticated;
create function public.orders_workspace(p_property uuid,p_filters jsonb default '{}')returns jsonb language plpgsql stable security definer set search_path=''as $$
declare result jsonb;prop public.properties;day date;financial boolean;query text:=left(trim(coalesce(p_filters->>'q','')),100);view text:=coalesce(p_filters->>'view','active');pg integer:=greatest(1,least(100000,coalesce((p_filters->>'page')::integer,1)));
begin
 if not private.order_access(p_property)then raise exception 'not permitted'using errcode='42501';end if;
 financial:=private.has_permission(p_property,'billing.manage')or private.has_permission(p_property,'finance.read');select * into prop from public.properties where id=p_property;day:=(now()at time zone prop.timezone)::date;
 with all_orders as materialized(select o.*,case when financial then case when o.reservation_id is not null then case when o.status='served'then 'room_posted'else 'room_pending'end when o.total=0 then 'complimentary'when exists(select 1 from public.payments where order_id=o.id)then 'paid'else 'unpaid'end end as payment_state from private.order_rows(p_property)o),filtered as materialized(select * from all_orders o where
 (query=''or strpos(lower(concat_ws(' ',o.id::text,o.table_label,o.room,o.current_room,o.guest_name,o.items::text)),lower(query))>0)
 and(coalesce(p_filters->>'kind','')=''or o.kind=p_filters->>'kind')and(coalesce(p_filters->>'priority','')=''or o.priority=p_filters->>'priority')
 and(case view when 'active'then o.status in('placed','preparing','ready')when 'placed'then o.status='placed'when 'preparing'then o.status='preparing'when 'ready'then o.status='ready'when 'served'then o.status='served'when 'cancelled'then o.status='cancelled'when 'overdue'then o.status in('placed','preparing','ready')and o.due_at<now()when 'unpaid'then financial and o.status='served'and o.payment_state='unpaid'else true end))
 select jsonb_build_object('total',(select count(*)from filtered),'page',pg,'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select * from filtered order by
 case when coalesce(p_filters->>'sort','priority')='priority'then case priority when 'urgent'then 0 when 'high'then 1 else 2 end else 0 end,
 case when coalesce(p_filters->>'sort','priority')='newest'then null else due_at end asc nulls last,
 case when coalesce(p_filters->>'sort','priority')='newest'then created_at end desc,created_at asc,id limit 20 offset(pg-1)*20)x),'[]'::jsonb),
 'stats',jsonb_build_object('placed',(select count(*)from all_orders where status='placed'),'preparing',(select count(*)from all_orders where status='preparing'),'ready',(select count(*)from all_orders where status='ready'),'overdue',(select count(*)from all_orders where status in('placed','preparing','ready')and due_at<now()),'served_today',(select count(*)from all_orders where status='served'and(served_at at time zone prop.timezone)::date=day),'unpaid',case when financial then(select count(*)from all_orders where status='served'and payment_state='unpaid')end))into result;
 return result||jsonb_build_object('currency',prop.currency,'timezone',prop.timezone,'day',day,'updated_at',now(),'can_place',private.has_permission(p_property,'orders.place'),'can_work',private.has_permission(p_property,'orders.write'),'can_menu',private.has_permission(p_property,'staff.manage'),'can_money',financial);
end $$;

create function public.order_setup(p_property uuid,p_query text default '',p_reservation uuid default null)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare result jsonb;
begin
 if not private.has_permission(p_property,'orders.place')then raise exception 'not permitted'using errcode='42501';end if;
 with stays as materialized(select r.id,g.full_name as guest_name,(select u.name from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.reservation_id=r.id and h.active limit 1)as room from public.reservations r join public.guests g on g.id=r.guest_id where r.property_id=p_property and r.status='checked_in'and not exists(select 1 from public.folios where reservation_id=r.id and status='closed')and(coalesce(trim(p_query),'')=''or strpos(lower(concat_ws(' ',g.full_name,r.id::text,(select u.name from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.reservation_id=r.id and h.active limit 1))),lower(left(trim(p_query),100)))>0))
 select jsonb_build_object('stay_total',(select count(*)from stays),'stays',coalesce((select jsonb_agg(to_jsonb(x))from(select * from stays order by guest_name,id limit 20)x),'[]'::jsonb))into result;
 return result||jsonb_build_object('selected',(select jsonb_build_object('id',r.id,'guest_name',g.full_name,'room',(select u.name from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.reservation_id=r.id and h.active limit 1))from public.reservations r join public.guests g on g.id=r.guest_id where r.id=p_reservation and r.property_id=p_property and r.status='checked_in'and not exists(select 1 from public.folios where reservation_id=r.id and status='closed')),
 'menu',coalesce((select jsonb_agg(to_jsonb(x)order by x.category,x.name)from(select mi.id,mi.version,mi.name,mi.price,mi.tax_rate_percent,mi.description,mi.dietary_notes,mi.prep_minutes,c.name as category from public.menu_items mi join public.menu_categories c on c.id=mi.category_id where mi.property_id=p_property and mi.active)x),'[]'::jsonb),'currency',(select currency from public.properties where id=p_property));
end $$;

create function public.order_detail(p_property uuid,p_id uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare o record;financial boolean;result jsonb;prop public.properties;
begin
 if not private.order_access(p_property)then raise exception 'not permitted'using errcode='42501';end if;
 select * into o from private.order_rows(p_property)where id=p_id;if not found then raise exception 'Order not found in this hotel.'using errcode='P0002';end if;
 select * into prop from public.properties where id=p_property;financial:=private.has_permission(p_property,'billing.manage')or private.has_permission(p_property,'finance.read');
 result:=jsonb_build_object('order',to_jsonb(o),'currency',prop.currency,'timezone',prop.timezone,'can_work',private.has_permission(p_property,'orders.write'),'can_cancel',private.has_permission(p_property,'orders.write')or private.has_permission(p_property,'orders.place'),'can_comment',private.has_permission(p_property,'orders.write')or private.has_permission(p_property,'orders.place'),'can_pay',private.has_permission(p_property,'billing.manage'),'can_refund',private.has_permission(p_property,'finance.write'),'can_money',financial,'can_reservation',private.has_permission(p_property,'reservations.read'),
 'comments',coalesce((select jsonb_agg(to_jsonb(x)order by x.created_at,x.id)from(select c.id,c.body,c.created_at,coalesce(pr.full_name,pr.email,'Staff')as author_name from public.order_comments c left join public.profiles pr on pr.id=c.author_id where c.order_id=o.id order by c.created_at desc,c.id desc limit 50)x),'[]'::jsonb),
 'events',coalesce((select jsonb_agg(to_jsonb(x))from(select e.id,e.event_type,e.details,e.created_at,coalesce(pr.full_name,pr.email,'Guest / system')as actor_name from public.kitchen_events e left join public.profiles pr on pr.id=e.actor_id where e.order_id=o.id and(financial or e.event_type not in('payment_recorded','refund_recorded'))order by e.created_at desc,e.id desc limit 40)x),'[]'::jsonb));
 if financial then
 result:=result||jsonb_build_object('payments',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'amount',p.amount,'method',p.method,'reference',p.reference,'created_at',p.created_at,'refunded',coalesce((select sum(amount)from public.refunds where payment_id=p.id),0),'refundable',p.amount-coalesce((select sum(amount)from public.refunds where payment_id=p.id),0)))from public.payments p where p.order_id=o.id),'[]'::jsonb),
 'refunds',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'amount',r.amount,'reason',r.reason,'created_at',r.created_at)order by r.created_at desc)from public.refunds r join public.payments p on p.id=r.payment_id where p.order_id=o.id),'[]'::jsonb),
 'folio_posted',exists(select 1 from public.folio_items where order_id=o.id and kind='order'));
 else result:=result||jsonb_build_object('payments','[]'::jsonb,'refunds','[]'::jsonb,'folio_posted',null);end if;return result;
end $$;

create function public.order_menu_setup(p_property uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'not permitted'using errcode='42501';end if;
 return jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(x)order by x.category,x.name)from(select mi.*,c.name as category from public.menu_items mi join public.menu_categories c on c.id=mi.category_id where mi.property_id=p_property)x),'[]'::jsonb),
 'categories',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name)order by position,name)from public.menu_categories where property_id=p_property),'[]'::jsonb),'currency',(select currency from public.properties where id=p_property));
end $$;
revoke all on function public.orders_workspace(uuid,jsonb),public.order_setup(uuid,text,uuid),public.order_detail(uuid,uuid),public.order_menu_setup(uuid)from public,anon;
grant execute on function public.orders_workspace(uuid,jsonb),public.order_setup(uuid,text,uuid),public.order_detail(uuid,uuid),public.order_menu_setup(uuid)to authenticated;
