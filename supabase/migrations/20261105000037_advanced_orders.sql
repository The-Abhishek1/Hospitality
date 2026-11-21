alter table public.menu_items add column description text not null default ''check(length(description)<=800),add column dietary_notes text not null default ''check(length(dietary_notes)<=200),add column prep_minutes integer check(prep_minutes between 1 and 240),add column version integer not null default 1;
alter table public.orders add column version integer not null default 1,add column priority text not null default 'normal'check(priority in('normal','high','urgent')),add column due_at timestamptz,add column preparing_at timestamptz,add column ready_at timestamptz,add column served_at timestamptz,add column cancelled_at timestamptz,add column source text not null default 'staff'check(source in('staff','guest_portal'));
update public.orders set source='guest_portal'where placed_by is null;
alter table public.kitchen_events add column details jsonb not null default '{}';
create function private.order_access(p_property uuid)returns boolean language sql stable security definer set search_path=''as $$select private.has_property_access(p_property)and(private.has_permission(p_property,'orders.read')or private.has_permission(p_property,'orders.place')or private.has_permission(p_property,'orders.write')or private.has_permission(p_property,'billing.manage')or private.has_permission(p_property,'finance.read'))$$;
revoke all on function private.order_access(uuid)from public,anon;
grant execute on function private.order_access(uuid)to authenticated;
drop policy orders_select on public.orders;
create policy orders_select on public.orders for select to authenticated using(private.order_access(property_id));
create table public.order_comments(id uuid primary key default gen_random_uuid(),tenant_id uuid not null,property_id uuid not null,order_id uuid not null,author_id uuid not null references public.profiles(id),body text not null check(length(trim(body))between 1 and 2000),created_at timestamptz not null default now(),foreign key(order_id,property_id)references public.orders(id,property_id)on delete cascade,foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade);
alter table public.order_comments enable row level security;
create policy order_comments_read on public.order_comments for select to authenticated using(private.order_access(property_id));
create table public.order_commands(id uuid primary key default gen_random_uuid(),tenant_id uuid not null,property_id uuid not null,request_id uuid not null,order_id uuid,menu_id uuid,action text not null,payload jsonb not null,result_id uuid not null,actor_id uuid,created_at timestamptz not null default now(),unique(property_id,request_id),foreign key(order_id,property_id)references public.orders(id,property_id)on delete cascade,foreign key(menu_id,property_id)references public.menu_items(id,property_id),foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade);
alter table public.order_commands enable row level security;
create policy order_commands_read on public.order_commands for select to authenticated using(private.has_permission(property_id,'staff.manage'));
create function private.order_version()returns trigger language plpgsql set search_path=''as $$begin new.version:=old.version+1;new.updated_at:=now();if new.status is distinct from old.status then
 if new.status='preparing'then new.preparing_at:=now();elsif new.status='ready'then new.ready_at:=now();elsif new.status='served'then new.served_at:=now();elsif new.status='cancelled'then new.cancelled_at:=now();end if;end if;return new;end $$;
create function private.menu_version()returns trigger language plpgsql set search_path=''as $$begin new.version:=old.version+1;return new;end $$;
revoke all on function private.order_version(),private.menu_version()from public,anon,authenticated;
create trigger order_version before update on public.orders for each row execute function private.order_version();
create trigger menu_version before update on public.menu_items for each row execute function private.menu_version();

create function private.lock_order(p_id uuid)returns public.orders language plpgsql security definer set search_path=''as $$
declare o public.orders;
begin
 select * into o from public.orders where id=p_id;
 if not found or not private.order_access(o.property_id)then raise exception 'not permitted'using errcode='42501';end if;
 if o.reservation_id is not null then perform private.billing_lock(o.reservation_id);end if;
 select * into o from public.orders where id=p_id for update;return o;
end $$;
revoke all on function private.lock_order(uuid)from public,anon,authenticated;

create or replace function private.place_order_core(p_property uuid,p_kind text,p_items jsonb,p_reservation uuid,p_table text,p_notes text,p_actor uuid)returns uuid language plpgsql security definer set search_path=''as $$
declare tenant uuid;r public.reservations;unit uuid;created_id uuid;sub numeric:=0;tax numeric:=0;count_items integer:=0;rec record;target integer;
begin
 select tenant_id into tenant from public.properties where id=p_property;if tenant is null then raise exception 'unknown property'using errcode='22023';end if;
 if p_kind is null or p_kind not in('restaurant','room_service')then raise exception 'Choose restaurant or room service.'using errcode='22023';end if;
 if p_items is null or jsonb_typeof(p_items)<>'array'or jsonb_array_length(p_items)not between 1 and 30 then raise exception 'Choose 1–30 different menu items.'using errcode='22023';end if;
 if length(coalesce(p_table,''))>40 or length(coalesce(p_notes,''))>2000 then raise exception 'Keep table labels under 40 characters and instructions under 2000.'using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements(p_items)x where coalesce(x->>'quantity','')!~'^[1-9][0-9]?$'or(x->>'quantity')::integer>50)then raise exception 'Use quantities of 1–50.'using errcode='22023';end if;
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
 sub:=sub+rec.price*rec.quantity;tax:=tax+round(rec.price*rec.quantity*rec.tax_rate_percent/100,2);count_items:=count_items+1;target:=greatest(target,rec.prep_minutes);end loop;
 if count_items<>jsonb_array_length(p_items)then raise exception 'A menu item is unavailable. Review the menu and try again.'using errcode='22023';end if;
 update public.orders set subtotal=sub,tax=tax,total=sub+tax,due_at=case when target is not null then now()+make_interval(mins=>target)end where id=created_id;
 insert into public.kitchen_events(tenant_id,property_id,order_id,event_type,actor_id)values(tenant,p_property,created_id,'placed',p_actor);return created_id;
end $$;

create or replace function public.set_order_status(p_id uuid,p_status text)returns void language plpgsql security definer set search_path=''as $$
declare o public.orders;f public.folios;tz text;
begin
 o:=private.lock_order(p_id);
 if not(private.has_permission(o.property_id,'orders.write')or(p_status='cancelled'and private.has_permission(o.property_id,'orders.place')))then raise exception 'not permitted'using errcode='42501';end if;
 if p_status is null or(o.status,p_status)not in(('placed','preparing'),('preparing','ready'),('ready','served'),('placed','cancelled'),('preparing','cancelled'))then raise exception 'invalid transition % -> %',o.status,p_status using errcode='22023';end if;
 if p_status='served'and o.reservation_id is not null then
 f:=private.billing_lock(o.reservation_id);if f.status='closed'then raise exception 'The guest folio is invoiced. Resolve billing before serving this room order.'using errcode='22023';end if;
 if(select status from public.reservations where id=o.reservation_id)<>'checked_in'then raise exception 'The guest is no longer in house. Resolve this room order with front desk.'using errcode='22023';end if;
 select timezone into tz from public.properties where id=o.property_id;
 insert into public.folio_items(tenant_id,property_id,folio_id,kind,description,amount,order_id,business_date,posted_by)values(o.tenant_id,o.property_id,f.id,'order','Order '||left(o.id::text,8),o.total,o.id,(now()at time zone tz)::date,auth.uid());end if;
 update public.orders set status=p_status where id=p_id;
 insert into public.kitchen_events(tenant_id,property_id,order_id,event_type,actor_id)values(o.tenant_id,o.property_id,o.id,p_status,auth.uid());
end $$;

create function public.orders_create(p_property uuid,p_request uuid,p_details jsonb)returns uuid language plpgsql security definer set search_path=''as $$
declare cmd public.order_commands;created_id uuid;items jsonb;total numeric;count_items integer;mins integer;
begin
 if not private.has_permission(p_property,'orders.place')then raise exception 'not permitted'using errcode='42501';end if;
 if p_request is null or p_details is null or jsonb_typeof(p_details)<>'object'then raise exception 'Reload the order form.'using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('orders-command:'||p_property::text||p_request::text,0));
 select * into cmd from public.order_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.action<>'create'or cmd.payload is distinct from p_details then raise exception 'Request ID already used for different order details.'using errcode='22023';end if;return cmd.result_id;end if;
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

create function public.order_action(p_property uuid,p_id uuid,p_version integer,p_request uuid,p_action text,p_details jsonb default '{}')returns uuid language plpgsql security definer set search_path=''as $$
declare o public.orders;cmd public.order_commands;result_id uuid;payment public.payments;refunded numeric;mins integer;target timestamptz;
begin
 if not private.order_access(p_property)then raise exception 'not permitted'using errcode='42501';end if;
 if p_request is null or p_details is null or jsonb_typeof(p_details)<>'object'then raise exception 'Reload this order.'using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('orders-command:'||p_property::text||p_request::text,0));
 select * into cmd from public.order_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.order_id is distinct from p_id or cmd.action<>p_action or cmd.payload is distinct from p_details then raise exception 'Request ID already used for different details.'using errcode='22023';end if;return cmd.result_id;end if;
 if not exists(select 1 from public.orders where id=p_id and property_id=p_property)then raise exception 'Order not found in this hotel.'using errcode='22023';end if;
 o:=private.lock_order(p_id);if p_action<>'comment'and o.version is distinct from p_version then raise exception 'This order changed. Refresh before continuing.'using errcode='40001';end if;result_id:=o.id;
 if p_action='status'then
 if p_details->>'status'='cancelled'and length(trim(coalesce(p_details->>'reason','')))not between 3 and 500 then raise exception 'Enter a cancellation reason of 3–500 characters.'using errcode='22023';end if;
 perform public.set_order_status(o.id,p_details->>'status');
 if p_details->>'status'='cancelled'then update public.kitchen_events set details=jsonb_build_object('reason',trim(p_details->>'reason'))where order_id=o.id and event_type='cancelled';end if;
 elsif p_action='triage'then
 if not private.has_permission(p_property,'orders.write')then raise exception 'not permitted'using errcode='42501';end if;
 if o.status not in('placed','preparing','ready')then raise exception 'This order is resolved.'using errcode='22023';end if;
 if coalesce(p_details->>'priority','')not in('normal','high','urgent')then raise exception 'Choose a priority.'using errcode='22023';end if;target:=o.due_at;
 if p_details->>'deadline'='clear'then target:=null;elsif p_details->>'deadline'='set'then mins:=(p_details->>'target_minutes')::integer;if mins is null or mins not between 1 and 1440 then raise exception 'Target must be 1–1440 minutes.'using errcode='22023';end if;target:=now()+make_interval(mins=>mins);elsif coalesce(p_details->>'deadline','keep')<>'keep'then raise exception 'Choose a deadline action.'using errcode='22023';end if;
 update public.orders set priority=p_details->>'priority',due_at=target where id=o.id;
 insert into public.kitchen_events(tenant_id,property_id,order_id,event_type,actor_id,details)values(o.tenant_id,p_property,o.id,'triaged',auth.uid(),jsonb_build_object('priority',p_details->>'priority','due_at',target));
 elsif p_action='comment'then
 if not(private.has_permission(p_property,'orders.write')or private.has_permission(p_property,'orders.place'))then raise exception 'not permitted'using errcode='42501';end if;
 if length(trim(coalesce(p_details->>'body','')))not between 1 and 2000 then raise exception 'Write a comment of 1–2000 characters.'using errcode='22023';end if;
 insert into public.order_comments(tenant_id,property_id,order_id,author_id,body)values(o.tenant_id,p_property,o.id,auth.uid(),trim(p_details->>'body'))returning id into result_id;
 elsif p_action='payment'then
 if not private.has_permission(p_property,'billing.manage')then raise exception 'not permitted'using errcode='42501';end if;
 if length(coalesce(p_details->>'reference',''))>120 or coalesce(p_details->>'method','')not in('cash','card','upi','bank_transfer','other')then raise exception 'Choose a payment method and a reference up to 120 characters.'using errcode='22023';end if;
 if p_details->>'expected_total' is null or(p_details->>'expected_total')::numeric is distinct from o.total then raise exception 'The total changed. Review it before recording payment.'using errcode='40001';end if;
 if o.total<=0 then raise exception 'This order has no payment due.'using errcode='22023';end if;
 result_id:=public.collect_order_payment(o.id,p_details->>'method',nullif(trim(p_details->>'reference'),''));
 update public.orders set updated_at=now()where id=o.id;
 insert into public.kitchen_events(tenant_id,property_id,order_id,event_type,actor_id)values(o.tenant_id,p_property,o.id,'payment_recorded',auth.uid());
 elsif p_action='refund'then
 if not private.has_permission(p_property,'finance.write')or o.reservation_id is not null then raise exception 'Direct-order refunds need finance access. Room charges are managed through Billing.'using errcode='42501';end if;
 select * into payment from public.payments where id=(p_details->>'payment_id')::uuid and order_id=o.id for update;if not found then raise exception 'Payment not found for this order.'using errcode='22023';end if;
 select coalesce(sum(amount),0)into refunded from public.refunds where payment_id=payment.id;
 if p_details->>'expected_refundable' is null or(p_details->>'expected_refundable')::numeric is distinct from payment.amount-refunded then raise exception 'Refund availability changed. Refresh before continuing.'using errcode='40001';end if;
 result_id:=public.refund_payment(payment.id,(p_details->>'amount')::numeric,p_details->>'reason');update public.orders set updated_at=now()where id=o.id;
 insert into public.kitchen_events(tenant_id,property_id,order_id,event_type,actor_id)values(o.tenant_id,p_property,o.id,'refund_recorded',auth.uid());
 else raise exception 'Choose a valid order action.'using errcode='22023';end if;
 insert into public.order_commands(tenant_id,property_id,request_id,order_id,action,payload,result_id,actor_id)values(o.tenant_id,p_property,p_request,o.id,p_action,p_details,result_id,auth.uid());return result_id;
end $$;

create function public.order_menu_save(p_property uuid,p_request uuid,p_id uuid,p_version integer,p_details jsonb)returns uuid language plpgsql security definer set search_path=''as $$
declare cmd public.order_commands;item public.menu_items;tenant uuid;category uuid;result_id uuid;new_price numeric;new_tax numeric;prep integer;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'not permitted'using errcode='42501';end if;
 if p_request is null or p_details is null or jsonb_typeof(p_details)<>'object'then raise exception 'Reload this menu form.'using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('orders-command:'||p_property::text||p_request::text,0));
 select * into cmd from public.order_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.action<>'menu'or cmd.menu_id is distinct from coalesce(p_id,cmd.result_id)or cmd.payload is distinct from p_details then raise exception 'Request ID already used for different menu details.'using errcode='22023';end if;return cmd.result_id;end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('order-menu:'||p_property::text,0));
 select tenant_id into tenant from public.properties where id=p_property;
 if p_id is not null then select * into item from public.menu_items where id=p_id and property_id=p_property for update;if not found then raise exception 'Menu item not found in this hotel.'using errcode='22023';end if;if item.version is distinct from p_version then raise exception 'This menu item changed. Refresh before saving.'using errcode='40001';end if;end if;
 if length(trim(coalesce(p_details->>'name','')))not between 2 and 120 or length(trim(coalesce(p_details->>'category','')))not between 2 and 80 or length(coalesce(p_details->>'description',''))>800 or length(coalesce(p_details->>'dietary_notes',''))>200 then raise exception 'Check item name, category, description and dietary notes.'using errcode='22023';end if;
 if coalesce(p_details->>'price','')!~'^[0-9]{1,10}(\.[0-9]{1,2})?$'or coalesce(p_details->>'tax','')!~'^[0-9]{1,3}(\.[0-9]{1,2})?$'then raise exception 'Enter non-negative prices and tax with up to two decimals.'using errcode='22023';end if;new_price:=(p_details->>'price')::numeric;new_tax:=(p_details->>'tax')::numeric;if new_tax>100 then raise exception 'Tax must be 0–100 percent.'using errcode='22023';end if;
 prep:=nullif(p_details->>'prep_minutes','')::integer;if prep is not null and prep not between 1 and 240 then raise exception 'Preparation targets must be 1–240 minutes.'using errcode='22023';end if;
 if exists(select 1 from public.menu_items where property_id=p_property and lower(trim(name))=lower(trim(p_details->>'name'))and id is distinct from p_id)then raise exception 'An item with this name already exists.'using errcode='23505';end if;
 select id into category from public.menu_categories where property_id=p_property and lower(trim(name))=lower(trim(p_details->>'category'))limit 1;
 if category is null then insert into public.menu_categories(tenant_id,property_id,name)values(tenant,p_property,trim(p_details->>'category'))returning id into category;end if;
 if p_id is null then insert into public.menu_items(tenant_id,property_id,category_id,name,price,tax_rate_percent,description,dietary_notes,prep_minutes,active)values(tenant,p_property,category,trim(p_details->>'name'),new_price,new_tax,coalesce(p_details->>'description',''),coalesce(p_details->>'dietary_notes',''),prep,coalesce((p_details->>'active')::boolean,true))returning id into result_id;
 else update public.menu_items set category_id=category,name=trim(p_details->>'name'),price=new_price,tax_rate_percent=new_tax,description=coalesce(p_details->>'description',''),dietary_notes=coalesce(p_details->>'dietary_notes',''),prep_minutes=prep,active=coalesce((p_details->>'active')::boolean,true)where id=p_id returning id into result_id;end if;
 insert into public.order_commands(tenant_id,property_id,request_id,menu_id,action,payload,result_id,actor_id)values(tenant,p_property,p_request,result_id,'menu',p_details,result_id,auth.uid());return result_id;
end $$;
revoke all on function public.orders_create(uuid,uuid,jsonb),public.order_action(uuid,uuid,integer,uuid,text,jsonb),public.order_menu_save(uuid,uuid,uuid,integer,jsonb)from public,anon;
grant execute on function public.orders_create(uuid,uuid,jsonb),public.order_action(uuid,uuid,integer,uuid,text,jsonb),public.order_menu_save(uuid,uuid,uuid,integer,jsonb)to authenticated;
