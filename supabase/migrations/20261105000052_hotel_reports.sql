create function private.report_capabilities(p_property uuid)returns jsonb language sql stable security definer set search_path=''as $$
 select jsonb_build_object('calendar',private.has_permission(p_property,'reservations.read')or private.has_permission(p_property,'finance.read')or private.has_permission(p_property,'billing.manage'),
 'finance',private.has_permission(p_property,'finance.read')or private.has_permission(p_property,'billing.manage'),
 'tasks',private.has_permission(p_property,'tasks.assign'),'requests',private.has_permission(p_property,'guest_requests.read')or private.has_permission(p_property,'guest_requests.manage'),'orders',private.order_access(p_property),
 'link_reservations',private.has_permission(p_property,'reservations.read'))
$$;
revoke all on function private.report_capabilities(uuid)from public,anon;
grant execute on function private.report_capabilities(uuid)to authenticated;
create function private.report_nightly_value(p_total numeric,p_nights integer,p_index integer)returns numeric language sql immutable set search_path=''as $$
 select case when p_nights>0 then trunc(p_total/p_nights,2)+case when p_index<round((p_total-trunc(p_total/p_nights,2)*p_nights)*100)::integer then 0.01 else 0 end else 0 end
$$;
revoke all on function private.report_nightly_value(numeric,integer,integer)from public,anon,authenticated;

create function private.report_slice(p_property uuid,p_from date,p_to date,p_caps jsonb,p_details boolean default true)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare tz text;start_at timestamptz;end_at timestamptz;result jsonb;ops jsonb;
 cal boolean:=(p_caps->>'calendar')::boolean;fin boolean:=(p_caps->>'finance')::boolean;task_access boolean:=(p_caps->>'tasks')::boolean;request_access boolean:=(p_caps->>'requests')::boolean;order_access boolean:=(p_caps->>'orders')::boolean;
begin
 select timezone into tz from public.properties where id=p_property;start_at:=p_from::timestamp at time zone tz;end_at:=(p_to+1)::timestamp at time zone tz;
 with days as materialized(select p_from+i as day from generate_series(0,p_to-p_from)i),rooms as materialized(select u.id,u.type_id,t.name as type_name from public.accommodation_units u join public.accommodation_types t on t.id=u.type_id where cal and u.property_id=p_property and u.active),
 scheduled as materialized(select d.day,h.reservation_id,r.source,u.type_id,u.type_name,private.report_nightly_value(r.total_amount,r.check_out-r.check_in,d.day-r.check_in)as value from days d join public.unit_holds h on h.during@>d.day and h.active and h.property_id=p_property and h.kind='reservation'join rooms u on u.id=h.unit_id join public.reservations r on r.id=h.reservation_id where r.property_id=p_property and r.status in('confirmed','checked_in','checked_out')and d.day>=r.check_in and d.day<r.check_out),
 blocked as materialized(select d.day,count(*)as count from days d join public.unit_holds h on h.during@>d.day and h.active and h.property_id=p_property and h.kind='block'join rooms u on u.id=h.unit_id group by d.day),
 booking_cohort as materialized(select r.id,r.source,r.status from public.reservations r where cal and r.property_id=p_property and r.created_at>=start_at and r.created_at<end_at),
 charges as materialized(select business_date as day,sum(amount)as total,sum(amount)filter(where kind='room')as rooms,sum(amount)filter(where kind='order')as orders,sum(amount)filter(where kind='adjustment')as adjustments from public.folio_items where fin and property_id=p_property and business_date between p_from and p_to group by business_date),
 receipts as materialized(select(created_at at time zone tz)::date as day,sum(amount)as amount from public.payments where fin and property_id=p_property and created_at>=start_at and created_at<end_at group by 1),
 refunds as materialized(select(created_at at time zone tz)::date as day,sum(amount)as amount from public.refunds where fin and property_id=p_property and created_at>=start_at and created_at<end_at group by 1),
 credits as materialized(select(issued_at at time zone tz)::date as day,sum(amount)as amount from public.credit_notes where fin and property_id=p_property and issued_at>=start_at and issued_at<end_at group by 1),
 direct_sales as materialized(select(served_at at time zone tz)::date as day,sum(total)as amount from public.orders where fin and property_id=p_property and reservation_id is null and status='served'and served_at>=start_at and served_at<end_at group by 1),
 task_done as materialized(select(completed_at at time zone tz)::date as day,count(*)as count from public.tasks where task_access and property_id=p_property and status='done'and completed_at>=start_at and completed_at<end_at group by 1),
 request_done as materialized(select(completed_at at time zone tz)::date as day,count(*)as count from public.guest_requests where request_access and property_id=p_property and status='completed'and completed_at>=start_at and completed_at<end_at group by 1),
 orders_served as materialized(select(served_at at time zone tz)::date as day,count(*)as count from public.orders where order_access and property_id=p_property and status='served'and served_at>=start_at and served_at<end_at group by 1),
 daily as materialized(select d.day,case when cal then(select count(*)from rooms)end as reference_rooms,case when cal then coalesce(b.count,0)end as blocked_rooms,case when cal then(select count(*)from rooms)-coalesce(b.count,0)end as available_room_nights,
 case when cal then(select count(*)from scheduled where day=d.day)end as booked_room_nights,case when cal and fin then coalesce((select sum(value)from scheduled where day=d.day),0)end as booked_room_value,
 case when fin then coalesce(c.total,0)end as folio_charges,case when fin then coalesce(c.rooms,0)end as posted_rooms,case when fin then coalesce(c.orders,0)end as posted_room_orders,case when fin then coalesce(c.adjustments,0)end as posted_adjustments,
 case when fin then coalesce(ds.amount,0)end as direct_sales,case when fin then coalesce(py.amount,0)end as receipts,case when fin then coalesce(rf.amount,0)end as refunds,case when fin then coalesce(cr.amount,0)end as invoice_credits,case when fin then coalesce(py.amount,0)-coalesce(rf.amount,0)end as net_cash,
 case when task_access then coalesce(td.count,0)end as tasks_completed,case when request_access then coalesce(rd.count,0)end as requests_completed,case when order_access then coalesce(os.count,0)end as orders_served
 from days d left join blocked b on b.day=d.day left join charges c on c.day=d.day left join direct_sales ds on ds.day=d.day left join receipts py on py.day=d.day left join refunds rf on rf.day=d.day left join credits cr on cr.day=d.day left join task_done td on td.day=d.day left join request_done rd on rd.day=d.day left join orders_served os on os.day=d.day)
 select jsonb_build_object('summary',jsonb_build_object('reference_rooms',case when cal then(select count(*)from rooms)end,'available_room_nights',(select sum(available_room_nights)from daily),'booked_room_nights',(select sum(booked_room_nights)from daily),'blocked_room_nights',(select sum(blocked_rooms)from daily),
 'occupancy',case when cal then(select round(100.0*sum(booked_room_nights)/nullif(sum(available_room_nights),0),2)from daily)end,
 'booked_room_value',(select sum(booked_room_value)::text from daily),'booked_adr',case when fin and cal then(select round(sum(booked_room_value)/nullif(sum(booked_room_nights),0),2)::text from daily)end,'booked_revpar',case when fin and cal then(select round(sum(booked_room_value)/nullif(sum(available_room_nights),0),2)::text from daily)end,
 'folio_charges',(select sum(folio_charges)::text from daily),'posted_rooms',(select sum(posted_rooms)::text from daily),'posted_room_orders',(select sum(posted_room_orders)::text from daily),'posted_adjustments',(select sum(posted_adjustments)::text from daily),'direct_sales',(select sum(direct_sales)::text from daily),'receipts',(select sum(receipts)::text from daily),'refunds',(select sum(refunds)::text from daily),'invoice_credits',(select sum(invoice_credits)::text from daily),'net_cash',(select sum(net_cash)::text from daily),
 'tasks_completed',(select sum(tasks_completed)from daily),'requests_completed',(select sum(requests_completed)from daily),'orders_served',(select sum(orders_served)from daily),
 'created_reservations',case when cal then(select count(*)from booking_cohort)end,'cohort_cancelled',case when cal then(select count(*)from booking_cohort where status='cancelled')end,'cohort_no_show',case when cal then(select count(*)from booking_cohort where status='no_show')end),
 'daily',case when p_details then coalesce((select jsonb_agg((to_jsonb(d)-'booked_room_value'-'folio_charges'-'posted_rooms'-'posted_room_orders'-'posted_adjustments'-'direct_sales'-'receipts'-'refunds'-'invoice_credits'-'net_cash')||jsonb_build_object('booked_room_value',booked_room_value::text,'folio_charges',folio_charges::text,'posted_rooms',posted_rooms::text,'posted_room_orders',posted_room_orders::text,'posted_adjustments',posted_adjustments::text,'direct_sales',direct_sales::text,'receipts',receipts::text,'refunds',refunds::text,'invoice_credits',invoice_credits::text,'net_cash',net_cash::text,'occupancy',round(100.0*booked_room_nights/nullif(available_room_nights,0),2))order by day)from daily d),'[]'::jsonb)else '[]'::jsonb end,
 'sources',case when p_details and cal then(select jsonb_agg(jsonb_build_object('source',src,'scheduled_reservations',(select count(distinct reservation_id)from scheduled where source=src),'room_nights',(select count(*)from scheduled where source=src),'booked_value',case when fin then(select coalesce(sum(value),0)::text from scheduled where source=src)end,'created',(select count(*)from booking_cohort where source=src),'cancelled_in_cohort',(select count(*)from booking_cohort where source=src and status='cancelled'),'no_show_in_cohort',(select count(*)from booking_cohort where source=src and status='no_show')))from(values('direct'),('walk_in'),('ota'))v(src))else '[]'::jsonb end,
 'room_types',case when p_details and cal then coalesce((select jsonb_agg(to_jsonb(x)order by x.name)from(select r.type_id,r.type_name as name,count(*)as room_nights,case when fin then sum(r.value)::text end as booked_value from scheduled r group by r.type_id,r.type_name)x),'[]'::jsonb)else '[]'::jsonb end)into result;
 if p_details and fin then
 result:=result||jsonb_build_object('payment_methods',coalesce((with methods as(
 select method from public.payments where property_id=p_property and created_at>=start_at and created_at<end_at
 union select p.method from public.refunds r join public.payments p on p.id=r.payment_id where r.property_id=p_property and r.created_at>=start_at and r.created_at<end_at)
 select jsonb_agg(to_jsonb(x)order by x.method)from(select m.method,
 (select count(*)from public.payments where property_id=p_property and method=m.method and created_at>=start_at and created_at<end_at)as payments,
 (select coalesce(sum(amount),0)::text from public.payments where property_id=p_property and method=m.method and created_at>=start_at and created_at<end_at)as received,
 (select coalesce(sum(r.amount),0)::text from public.refunds r join public.payments p on p.id=r.payment_id where r.property_id=p_property and p.method=m.method and r.created_at>=start_at and r.created_at<end_at)as refunded
 from methods m)x),'[]'::jsonb));
 else result:=result||jsonb_build_object('payment_methods','[]'::jsonb);end if;
 if p_details then
 ops:=jsonb_build_object('tasks',case when task_access then(select jsonb_build_object('created',count(*)filter(where created_at>=start_at and created_at<end_at),'completed',count(*)filter(where status='done'and completed_at>=start_at and completed_at<end_at),'completed_with_target',count(*)filter(where status='done'and completed_at>=start_at and completed_at<end_at and due_at is not null),'within_target',count(*)filter(where status='done'and completed_at>=start_at and completed_at<end_at and due_at is not null and completed_at<=due_at),'average_minutes',round(avg(extract(epoch from(completed_at-created_at))/60)filter(where status='done'and completed_at>=start_at and completed_at<end_at and completed_at>=created_at),1),'open_now',count(*)filter(where status in('open','in_progress')),'overdue_now',count(*)filter(where status in('open','in_progress')and due_at<now()))from public.tasks where property_id=p_property)end,
 'requests',case when request_access then(select jsonb_build_object('created',count(*)filter(where created_at>=start_at and created_at<end_at),'completed',count(*)filter(where status='completed'and completed_at>=start_at and completed_at<end_at),'completed_with_target',count(*)filter(where status='completed'and completed_at>=start_at and completed_at<end_at and due_at is not null),'within_target',count(*)filter(where status='completed'and completed_at>=start_at and completed_at<end_at and due_at is not null and completed_at<=due_at),'average_minutes',round(avg(extract(epoch from(completed_at-created_at))/60)filter(where status='completed'and completed_at>=start_at and completed_at<end_at and completed_at>=created_at),1),'open_now',count(*)filter(where status in('new','in_progress')),'overdue_now',count(*)filter(where status in('new','in_progress')and due_at<now()))from public.guest_requests where property_id=p_property)end,
 'orders',case when order_access then(select jsonb_build_object('created',count(*)filter(where created_at>=start_at and created_at<end_at),'completed',count(*)filter(where status='served'and served_at>=start_at and served_at<end_at),'completed_with_target',count(*)filter(where status='served'and served_at>=start_at and served_at<end_at and due_at is not null),'within_target',count(*)filter(where status='served'and served_at>=start_at and served_at<end_at and due_at is not null and served_at<=due_at),'average_minutes',round(avg(extract(epoch from(served_at-created_at))/60)filter(where status='served'and served_at>=start_at and served_at<end_at and served_at>=created_at),1),'open_now',count(*)filter(where status in('placed','preparing','ready')),'overdue_now',count(*)filter(where status in('placed','preparing','ready')and due_at<now()))from public.orders where property_id=p_property)end,
 'feedback',case when request_access then(select jsonb_build_object('count',count(*),'average',round(avg(rating),2),'guest_portal',count(*)filter(where recorded_via='guest'),'staff_reported',count(*)filter(where recorded_via='staff_reported'),'legacy',count(*)filter(where recorded_via='legacy'))from public.guest_request_feedback where property_id=p_property and created_at>=start_at and created_at<end_at)end);
 result:=result||jsonb_build_object('operations',ops);
 end if;return result;
end $$;
revoke all on function private.report_slice(uuid,date,date,jsonb,boolean)from public,anon,authenticated;

create function public.hotel_report(p_property uuid,p_from date default null,p_to date default null)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare p public.properties;caps jsonb;first_day date;last_day date;span integer;current_result jsonb;previous_result jsonb;
begin
 if not private.has_property_access(p_property)then raise exception 'not permitted'using errcode='42501';end if;
 caps:=private.report_capabilities(p_property);
 if not exists(select 1 from jsonb_each_text(caps)c where c.key<>'link_reservations'and c.value='true')then raise exception 'Reporting access required for this hotel.'using errcode='42501';end if;
 select * into p from public.properties where id=p_property;last_day:=coalesce(p_to,(now()at time zone p.timezone)::date);first_day:=coalesce(p_from,last_day-29);
 if first_day<date '2000-01-01'or last_day>date '2100-12-31'or last_day<first_day or last_day-first_day>365 then raise exception 'Choose a report range of 1–366 days between 2000 and 2100.'using errcode='22023';end if;
 span:=last_day-first_day+1;current_result:=private.report_slice(p_property,first_day,last_day,caps,true);previous_result:=private.report_slice(p_property,first_day-span,first_day-1,caps,false);
 return current_result||jsonb_build_object('property_name',p.name,'currency',p.currency,'timezone',p.timezone,'from',first_day,'to',last_day,'days',span,'previous_from',first_day-span,'previous_to',first_day-1,'previous',previous_result->'summary','capabilities',caps,'generated_at',now(),'today',(now()at time zone p.timezone)::date);
end $$;
revoke all on function public.hotel_report(uuid,date,date)from public,anon;
grant execute on function public.hotel_report(uuid,date,date)to authenticated;

create index if not exists report_folio_business_date on public.folio_items(property_id,business_date);
create index if not exists report_payments_created on public.payments(property_id,created_at);
create index if not exists report_refunds_created on public.refunds(property_id,created_at);
create index if not exists report_credits_issued on public.credit_notes(property_id,issued_at);
create index if not exists report_reservations_created on public.reservations(property_id,created_at);
create index if not exists report_orders_served on public.orders(property_id,served_at)where status='served';
create index if not exists report_tasks_completed on public.tasks(property_id,completed_at)where status='done';
create index if not exists report_requests_completed on public.guest_requests(property_id,completed_at)where status='completed';
create index if not exists report_feedback_created on public.guest_request_feedback(property_id,created_at);
