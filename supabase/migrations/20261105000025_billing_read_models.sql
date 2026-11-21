create function private.billing_stays(p_property uuid)
returns table(reservation_id uuid,folio_id uuid,guest_name text,phone text,check_in date,check_out date,stay_status text,room text,currency char(3),room_total numeric,folio_status text,
 charges numeric,paid numeric,refunded numeric,credited numeric,balance numeric,unposted_room numeric,projected_balance numeric,invoice_id uuid,invoice_number text)
language sql stable security definer set search_path='' as $$
 select r.id,f.id,g.full_name,g.phone,r.check_in,r.check_out,r.status,
 (select u.name from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.reservation_id=r.id order by h.active desc,h.created_at desc limit 1),
 r.currency,r.total_amount,f.status,charge.total,paid.total,refunded.total,credited.total,
 charge.total-paid.total+refunded.total-credited.total,unposted.amount,charge.total-paid.total+refunded.total-credited.total+unposted.amount,inv.id,inv.number
 from public.reservations r left join public.guests g on g.id=r.guest_id left join public.folios f on f.reservation_id=r.id left join public.invoices inv on inv.folio_id=f.id
 cross join lateral(select coalesce(sum(amount),0) as total,coalesce(sum(amount) filter(where kind='room'),0) as room from public.folio_items where folio_id=f.id)charge
 cross join lateral(select coalesce(sum(amount),0) as total from public.payments where folio_id=f.id)paid
 cross join lateral(select coalesce(sum(rf.amount),0) as total from public.refunds rf join public.payments p on p.id=rf.payment_id where p.folio_id=f.id)refunded
 cross join lateral(select coalesce(sum(amount),0) as total from public.credit_notes where folio_id=f.id)credited
 cross join lateral(select case when r.status in ('confirmed','checked_in') and coalesce(f.status,'open')='open' then greatest(0,r.total_amount-charge.room) else 0 end as amount)unposted
 where r.property_id=p_property and (f.id is not null or r.status in ('checked_in','checked_out'))
$$;

create function private.billing_ledger(p_folio uuid)
returns table(id uuid,entry_order bigint,created_at timestamptz,kind text,description text,amount numeric,method text,reference text,actor_name text)
language sql stable security definer set search_path='' as $$
 select i.id,i.entry_order,i.created_at,i.kind,i.description,i.amount,null::text,null::text,pr.full_name from public.folio_items i left join public.profiles pr on pr.id=i.posted_by where i.folio_id=p_folio
 union all
 select p.id,p.entry_order,p.created_at,'payment','Payment recorded',-p.amount,p.method,p.reference,pr.full_name from public.payments p left join public.profiles pr on pr.id=p.collected_by where p.folio_id=p_folio
 union all
 select r.id,r.entry_order,r.created_at,'refund',r.reason,r.amount,p.method,null::text,pr.full_name from public.refunds r join public.payments p on p.id=r.payment_id left join public.profiles pr on pr.id=r.refunded_by where p.folio_id=p_folio
 union all
 select c.id,c.entry_order,c.issued_at,'credit_note',c.number||' · '||c.reason,-c.amount,null::text,c.number,pr.full_name from public.credit_notes c left join public.profiles pr on pr.id=c.issued_by where c.folio_id=p_folio
$$;

create function public.billing_workspace(p_property uuid,p_filters jsonb default '{}') returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare p public.properties;d date;q text:=left(trim(coalesce(p_filters->>'q','')),100);view_filter text:=coalesce(p_filters->>'view','open');balance_filter text:=coalesce(p_filters->>'balance','all');pg int:=greatest(1,least(100000,coalesce((p_filters->>'page')::int,1)));result jsonb;start_at timestamptz;end_at timestamptz;
begin
 if not(private.has_permission(p_property,'finance.read') or private.has_permission(p_property,'billing.manage')) then raise exception 'not permitted' using errcode='42501';end if;
 select * into p from public.properties where id=p_property;d:=(now() at time zone p.timezone)::date;start_at:=d::timestamp at time zone p.timezone;end_at:=(d+1)::timestamp at time zone p.timezone;
 with all_stays as materialized(select * from private.billing_stays(p_property)),filtered as materialized(
 select * from all_stays b where(q='' or strpos(lower(concat_ws(' ',b.guest_name,b.phone,b.reservation_id::text,b.invoice_number)),lower(q))>0)
 and(case view_filter when 'open' then coalesce(b.folio_status,'open')='open' when 'invoiced' then b.folio_status='closed' when 'departures' then b.stay_status='checked_in' and b.check_out=d else true end)
 and(case balance_filter when 'due' then b.balance>0 when 'credit' then b.balance<0 when 'settled' then b.balance=0 else true end))
 select jsonb_build_object('total',(select count(*) from filtered),'page',pg,'rows',coalesce((select jsonb_agg(to_jsonb(x)) from(select * from filtered order by check_out,reservation_id limit 20 offset(pg-1)*20)x),'[]'::jsonb),
 'stats',jsonb_build_object('open',(select count(*) from all_stays where coalesce(folio_status,'open')='open'),
 'outstanding',(select coalesce(sum(greatest(balance,0)),0) from all_stays),'guest_credit',(select coalesce(sum(greatest(-balance,0)),0) from all_stays),
 'collected',(select coalesce(sum(amount),0) from public.payments where property_id=p_property and created_at>=start_at and created_at<end_at),
 'refunded',(select coalesce(sum(amount),0) from public.refunds where property_id=p_property and created_at>=start_at and created_at<end_at))) into result;
 return result||jsonb_build_object('day',d,'currency',p.currency,'timezone',p.timezone,'can_manage',private.has_permission(p_property,'billing.manage'),'can_finance_write',private.has_permission(p_property,'finance.write'),
 'audits',coalesce((select jsonb_agg(to_jsonb(x)) from(select business_date,summary,run_at from public.night_audits where property_id=p_property order by business_date desc limit 10)x),'[]'::jsonb),
 'audit_runs',coalesce((select jsonb_agg(to_jsonb(x)) from(select business_date,summary,run_at,pr.full_name as actor_name from public.night_audit_runs nr left join public.profiles pr on pr.id=nr.run_by where nr.property_id=p_property order by nr.run_at desc,nr.id desc limit 10)x),'[]'::jsonb));
end $$;

create function public.billing_detail(p_property uuid,p_reservation uuid,p_page int default 1) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r public.reservations;b record;f public.folios;result jsonb;pg int:=greatest(1,least(100000,p_page));
begin
 if not(private.has_permission(p_property,'finance.read') or private.has_permission(p_property,'billing.manage')) then raise exception 'not permitted' using errcode='42501';end if;
 select * into r from public.reservations where id=p_reservation and property_id=p_property;
 if not found then raise exception 'Folio not found in this hotel.' using errcode='P0002';end if;
 select * into f from public.folios where reservation_id=r.id;
 select * into b from private.billing_stays(p_property) where reservation_id=r.id;
 result:=jsonb_build_object('stay',jsonb_build_object('id',r.id,'status',r.status,'check_in',r.check_in,'check_out',r.check_out,'total_amount',r.total_amount,'currency',r.currency),
 'guest',(select jsonb_build_object('name',full_name,'phone',phone,'email',email) from public.guests where id=r.guest_id),
 'summary',case when b.reservation_id is not null then to_jsonb(b) else jsonb_build_object('folio_id',f.id,'balance',0,'charges',0,'paid',0,'refunded',0,'credited',0,'unposted_room',case when r.status in ('confirmed','checked_in') then r.total_amount else 0 end,'projected_balance',case when r.status in ('confirmed','checked_in') then r.total_amount else 0 end) end,
 'can_manage',private.has_permission(p_property,'billing.manage'),'can_finance_write',private.has_permission(p_property,'finance.write'),'can_reservations',private.has_permission(p_property,'reservations.read'),
 'page',pg,'ledger_total',(select count(*) from private.billing_ledger(f.id)),
 'ledger',coalesce((select jsonb_agg(to_jsonb(x)) from(select *,sum(amount) over(order by created_at,entry_order,id) as running_balance from private.billing_ledger(f.id) order by created_at,entry_order,id limit 50 offset(pg-1)*50)x),'[]'::jsonb),
 'payments',coalesce((select jsonb_agg(to_jsonb(x)) from(select p.id,p.amount,p.method,p.reference,p.created_at,p.amount-coalesce((select sum(amount) from public.refunds where payment_id=p.id),0) as refundable from public.payments p where p.folio_id=f.id order by p.created_at desc,p.entry_order desc limit 200)x),'[]'::jsonb),
 'credits',coalesce((select jsonb_agg(jsonb_build_object('id',id,'number',number,'amount',amount,'reason',reason,'issued_at',issued_at,'invoice_id',invoice_id) order by issued_at) from public.credit_notes where folio_id=f.id),'[]'::jsonb),
 'events',coalesce((select jsonb_agg(to_jsonb(x)) from(select e.action,e.created_at,pr.full_name as actor_name from public.billing_events e left join public.profiles pr on pr.id=e.actor_id where e.reservation_id=r.id order by e.created_at desc,e.id desc limit 20)x),'[]'::jsonb),
 'pending_orders',(select count(*) from public.orders where reservation_id=r.id and status in ('placed','preparing','ready')));
 return result;
end $$;

create function public.billing_invoice(p_property uuid,p_invoice uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare inv public.invoices;f public.folios;r public.reservations;p public.properties;snap jsonb;
begin
 if not(private.has_permission(p_property,'finance.read') or private.has_permission(p_property,'billing.manage')) then raise exception 'not permitted' using errcode='42501';end if;
 select * into inv from public.invoices where id=p_invoice and property_id=p_property;
 if not found then raise exception 'Invoice not found in this hotel.' using errcode='P0002';end if;
 select * into f from public.folios where id=inv.folio_id;select * into r from public.reservations where id=f.reservation_id;snap:=inv.snapshot;
 if snap is null then
  select * into p from public.properties where id=p_property;
  snap:=jsonb_build_object('legacy_snapshot',true,'property',jsonb_build_object('name',p.name,'address',p.address,'city',p.city,'country_code',p.country_code,'email',p.contact_email,'phone',p.contact_phone,'timezone',p.timezone),
  'guest',(select jsonb_build_object('name',full_name,'phone',phone,'email',email) from public.guests where id=r.guest_id),'stay',jsonb_build_object('id',r.id,'check_in',r.check_in,'check_out',r.check_out),
  'items',coalesce((select jsonb_agg(jsonb_build_object('description',description,'kind',kind,'amount',amount,'date',business_date) order by business_date,entry_order) from public.folio_items where folio_id=f.id),'[]'::jsonb),'total',inv.total,'currency',inv.currency,'issued_at',inv.issued_at);
 end if;
 return jsonb_build_object('id',inv.id,'number',inv.number,'issued_at',inv.issued_at,'snapshot',snap,'reservation_id',r.id,
 'credits',coalesce((select jsonb_agg(jsonb_build_object('id',id,'number',number,'amount',amount,'currency',currency,'reason',reason,'issued_at',issued_at) order by issued_at) from public.credit_notes where invoice_id=inv.id),'[]'::jsonb));
end $$;

create function public.billing_export(p_property uuid,p_reservation uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare f public.folios;currency text;result jsonb;
begin
 if not(private.has_permission(p_property,'finance.read') or private.has_permission(p_property,'billing.manage')) then raise exception 'not permitted' using errcode='42501';end if;
 select r.currency into currency from public.reservations r where r.id=p_reservation and r.property_id=p_property;
 if not found then raise exception 'Folio not found in this hotel.' using errcode='P0002';end if;
 select * into f from public.folios where reservation_id=p_reservation;
 if(select count(*) from private.billing_ledger(f.id))>10000 then raise exception 'This folio exceeds the export limit of 10,000 entries.' using errcode='54000';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at,x.entry_order),'[]'::jsonb) into result from(select *,sum(amount) over(order by created_at,entry_order,id) as running_balance from private.billing_ledger(f.id))x;
 return jsonb_build_object('currency',currency,'entries',result);
end $$;
revoke all on function private.billing_stays(uuid),private.billing_ledger(uuid) from public,anon,authenticated;
revoke all on function public.billing_workspace(uuid,jsonb),public.billing_detail(uuid,uuid,int),public.billing_invoice(uuid,uuid),public.billing_export(uuid,uuid) from public,anon;
grant execute on function public.billing_workspace(uuid,jsonb),public.billing_detail(uuid,uuid,int),public.billing_invoice(uuid,uuid),public.billing_export(uuid,uuid) to authenticated;
