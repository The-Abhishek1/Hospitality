-- Guest pages show guest-authored request notes, never staff-only request notes.
create or replace function public.portal_workspace(p_token text,p_filters jsonb default '{}')returns jsonb language plpgsql security definer set search_path=''as $$
declare r public.reservations;f public.folios;today date;links jsonb;result jsonb;menu_page integer;request_page integer;order_page integer;bill_page integer;query text;category_filter text;
begin
 r:=private.portal_reservation(p_token);
 if p_filters is null or jsonb_typeof(p_filters)<>'object'then raise exception 'Invalid page filters.'using errcode='22023';end if;
 menu_page:=greatest(1,least(100000,coalesce((p_filters->>'menu_page')::integer,1)));request_page:=greatest(1,least(100000,coalesce((p_filters->>'request_page')::integer,1)));order_page:=greatest(1,least(100000,coalesce((p_filters->>'order_page')::integer,1)));bill_page:=greatest(1,least(100000,coalesce((p_filters->>'bill_page')::integer,1)));
 query:=lower(left(trim(coalesce(p_filters->>'q','')),100));category_filter:=coalesce(p_filters->>'category','');
 select(now()at time zone timezone)::date into today from public.properties where id=r.property_id;
 select * into f from public.folios where reservation_id=r.id;
 select coalesce(data,'{}')into links from public.whatsapp_guest_settings where property_id=r.property_id;
 with menu_rows as materialized(select m.id,m.version,m.category_id,c.name as category,m.name,m.description,m.dietary_notes,m.price::text as price,m.tax_rate_percent::text as tax_rate_percent,m.prep_minutes from public.menu_items m join public.menu_categories c on c.id=m.category_id where m.property_id=r.property_id and m.active and(query=''or strpos(lower(m.name||' '||m.description||' '||m.dietary_notes),query)>0)and(category_filter=''or m.category_id::text=category_filter)),
 charges as(select coalesce(sum(amount),0)as total,coalesce(sum(amount)filter(where kind='room'),0)as room from public.folio_items where folio_id=f.id),
 receipts as(select coalesce(sum(amount),0)as total from public.payments where folio_id=f.id),
 refunds as(select coalesce(sum(rf.amount),0)as total from public.refunds rf join public.payments p on p.id=rf.payment_id where p.folio_id=f.id),
 credits as(select coalesce(sum(amount),0)as total from public.credit_notes where folio_id=f.id),
 pending as(select coalesce(sum(total),0)as total from public.orders where reservation_id=r.id and status in('placed','preparing','ready')),
 ledger as materialized(
 select i.id,i.entry_order,i.business_date as day,i.created_at,i.kind,i.description,i.amount from public.folio_items i where i.folio_id=f.id
 union all select p.id,p.entry_order,(p.created_at at time zone pr.timezone)::date,p.created_at,'payment','Payment received',-p.amount from public.payments p join public.properties pr on pr.id=r.property_id where p.folio_id=f.id
 union all select rf.id,rf.entry_order,(rf.created_at at time zone pr.timezone)::date,rf.created_at,'refund','Refund recorded',rf.amount from public.refunds rf join public.payments p on p.id=rf.payment_id join public.properties pr on pr.id=r.property_id where p.folio_id=f.id
 union all select c.id,c.entry_order,(c.issued_at at time zone pr.timezone)::date,c.issued_at,'credit_note','Invoice credit '||c.number,-c.amount from public.credit_notes c join public.properties pr on pr.id=r.property_id where c.folio_id=f.id
 )select jsonb_build_object(
 'today',today,'updated_at',now(),'stay',jsonb_build_object('id',r.id,'reference',upper(left(r.id::text,8)),'check_in',r.check_in,'check_out',r.check_out,'status',r.status,'adults',r.adults,'children',r.children,'currency',r.currency,'room_total',r.total_amount::text,'nights',r.check_out-r.check_in),
 'property',private.property_guest_info(r.property_id),
 'guest',(select jsonb_build_object('full_name',g.full_name,'email',coalesce(g.email,''),'phone',coalesce(g.phone,''))from public.guests g where g.id=r.guest_id),
 'arrival',(select to_jsonb(d)-'tenant_id'-'property_id'-'reservation_id'from public.guest_arrival_details d where reservation_id=r.id),
 'room',(select jsonb_build_object('name',u.name,'type',t.name)from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id join public.accommodation_types t on t.id=u.type_id where h.reservation_id=r.id order by h.active desc,h.created_at desc limit 1),
 'links',jsonb_build_object('maps_url',case when private.whatsapp_studio_url(links->>'maps_url')then links->>'maps_url'end,'website_url',case when private.whatsapp_studio_url(links->>'website_url')then links->>'website_url'end,'hotel_photo_url',case when private.whatsapp_studio_url(links->>'hotel_photo_url')then links->>'hotel_photo_url'end,'review_url',case when r.status='checked_out'and private.whatsapp_studio_url(links->>'review_url')then links->>'review_url'end),
 'capabilities',jsonb_build_object('details',r.status in('confirmed','checked_in'),'documents',r.status in('confirmed','checked_in'),'requests',r.status in('confirmed','checked_in'),'order',r.status='checked_in'and coalesce(f.status,'open')='open','checkin',r.status='confirmed'and today>=r.check_in and today<r.check_out,'checkout',r.status='checked_in'),
 'services',coalesce((select jsonb_agg(to_jsonb(x))from(select s.id,s.name,s.description,c.name as category from public.service_catalog s join public.service_categories c on c.id=s.category_id where s.property_id=r.property_id and s.active order by c.name,s.name limit 200)x),'[]'::jsonb),
 'request_total',(select count(*)from public.guest_requests where reservation_id=r.id),
 'requests',coalesce((select jsonb_agg(to_jsonb(x))from(select q.id,q.version,q.title,case when q.source='portal'then q.notes end as notes,q.status,q.created_at,q.completed_at,exists(select 1 from public.guest_request_feedback where guest_request_id=q.id)as rated,(select rating from public.guest_request_feedback where guest_request_id=q.id)as rating,
 q.status='new'and not exists(select 1 from public.tasks where guest_request_id=q.id and status not in('open','cancelled'))as can_cancel,
 (select intent from public.guest_stay_requests where guest_request_id=q.id)as intent
 from public.guest_requests q where q.reservation_id=r.id order by q.created_at desc,q.id desc limit 10 offset(request_page-1)*10)x),'[]'::jsonb),
 'stay_requests',coalesce((select jsonb_agg(jsonb_build_object('intent',a.intent,'id',q.id,'status',q.status))from public.guest_stay_requests a join public.guest_requests q on q.id=a.guest_request_id where a.reservation_id=r.id and q.reservation_id=r.id and q.status in('new','in_progress')),'[]'::jsonb),
 'menu_total',(select count(*)from menu_rows),'menu',coalesce((select jsonb_agg(to_jsonb(x))from(select * from menu_rows order by category,name,id limit 20 offset(menu_page-1)*20)x),'[]'::jsonb),
 'menu_categories',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name)order by c.name)from public.menu_categories c where c.property_id=r.property_id and exists(select 1 from public.menu_items where category_id=c.id and active)),'[]'::jsonb),
 'order_total',(select count(*)from public.orders where reservation_id=r.id),
 'orders',coalesce((select jsonb_agg(to_jsonb(x))from(select o.id,o.status,o.created_at,o.total::text as total,o.subtotal::text as subtotal,o.tax::text as tax,o.served_at,case when o.source='guest_portal'then o.notes end as notes,
 (select jsonb_agg(jsonb_build_object('name',name_snapshot,'quantity',quantity,'unit_price',unit_price::text)order by id)from public.order_items where order_id=o.id)as items
 from public.orders o where o.reservation_id=r.id order by o.created_at desc,o.id desc limit 10 offset(order_page-1)*10)x),'[]'::jsonb),
 'documents',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'doc_type',d.doc_type,'status',d.status,'size_bytes',d.size_bytes,'created_at',d.created_at,'uploaded_at',d.uploaded_at)order by d.created_at desc,d.id)from public.guest_documents d where reservation_id=r.id),'[]'::jsonb),
 'bill',jsonb_build_object('exists',f.id is not null,'folio_status',f.status,'charges',(select total::text from charges),'payments',(select total::text from receipts),'refunds',(select total::text from refunds),'credits',(select total::text from credits),
 'balance',(select(c.total-p.total+rf.total-cr.total)::text from charges c,receipts p,refunds rf,credits cr),
 'unposted_room',(select(case when r.status in('confirmed','checked_in')and coalesce(f.status,'open')='open'then greatest(0,r.total_amount-c.room)else 0 end)::text from charges c),
 'pending_orders',(select total::text from pending),
 'estimated_balance',(select(c.total-p.total+rf.total-cr.total+po.total+case when r.status in('confirmed','checked_in')and coalesce(f.status,'open')='open'then greatest(0,r.total_amount-c.room)else 0 end)::text from charges c,receipts p,refunds rf,credits cr,pending po),
 'entries_total',(select count(*)from ledger),'entries',coalesce((select jsonb_agg(to_jsonb(x))from(select id,day,created_at,kind,description,amount::text as amount from ledger order by entry_order desc,id desc limit 20 offset(bill_page-1)*20)x),'[]'::jsonb),
 'invoice',(select jsonb_build_object('number',number,'issued_at',issued_at,'total',total::text,'currency',currency)from public.invoices where folio_id=f.id))
 )into result;return result;
end $$;
