-- Keep receipt references, reservation summaries and exports consistent.
create or replace function public.billing_action(p_property uuid,p_reservation uuid,p_request uuid,p_action text,p_details jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.reservations;f public.folios;e public.billing_events;id uuid;amount numeric;balance numeric;payment public.payments;
begin
 if p_action='refund' then
  if not private.has_permission(p_property,'finance.write') then raise exception 'not permitted' using errcode='42501';end if;
 elsif not private.has_permission(p_property,'billing.manage') then raise exception 'not permitted' using errcode='42501';end if;
 if p_details is null or jsonb_typeof(p_details)<>'object' then raise exception 'Invalid billing details.' using errcode='22023';end if;
 if p_request is null then raise exception 'Reload this form and try again.' using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_property::text||p_request::text,0));
 select * into e from public.billing_events where property_id=p_property and request_id=p_request;
 if found then
  if e.reservation_id is distinct from p_reservation or e.action<>p_action or e.payload is distinct from p_details then raise exception 'This request was already used for different details. Reload the form.' using errcode='22023';end if;
  return jsonb_build_object('id',e.result_id,'action',e.action);
 end if;
 select * into r from public.reservations where public.reservations.id=p_reservation and property_id=p_property for update;
 if not found then raise exception 'Reservation not found in this hotel.' using errcode='22023';end if;
 f:=private.billing_lock(r.id);balance:=private.folio_balance_raw(f.id);
 if p_details?'expected_balance' and balance<>(p_details->>'expected_balance')::numeric then raise exception 'The balance changed. Refresh and review the latest activity.' using errcode='40001';end if;
 if p_action='post_rooms' then
  if r.status<>'checked_in' then raise exception 'Room nights can be posted here for in-house guests only.' using errcode='22023';end if;
  id:=public.post_room_charges(r.id);
 elsif p_action='payment' then
  amount:=(p_details->>'amount')::numeric;perform private.billing_amount(amount);
  if r.status not in ('confirmed','checked_in','checked_out') then raise exception 'Payments cannot be added to a cancelled or no-show stay.' using errcode='22023';end if;
  if amount>greatest(0,balance) and coalesce((p_details->>'allow_credit')::boolean,false)=false then raise exception 'This payment exceeds the posted balance. Confirm a deposit or overpayment explicitly.' using errcode='22023';end if;
  if (p_details->>'method') in ('card','upi','bank_transfer') then
   if length(trim(coalesce(p_details->>'reference','')))<3 then raise exception 'Enter the payment transaction or receipt reference.' using errcode='22023';end if;
   perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('payment-reference:'||p_property::text||':'||(p_details->>'method')||':'||lower(trim(p_details->>'reference')),0));
   if exists(select 1 from public.payments where property_id=p_property and method=p_details->>'method' and lower(trim(reference))=lower(trim(p_details->>'reference'))) then raise exception 'This payment transaction reference is already recorded.' using errcode='23505';end if;
  end if;
  id:=public.collect_folio_payment(f.id,amount,p_details->>'method',p_details->>'reference');
 elsif p_action in ('charge','credit') then
  amount:=(p_details->>'amount')::numeric;perform private.billing_amount(amount);
  if p_action='credit' then amount:=-amount;end if;
  perform public.post_folio_charge(r.id,p_details->>'description',amount);
  select public.folio_items.id into id from public.folio_items where folio_id=f.id order by entry_order desc limit 1;
 elsif p_action='refund' then
  select * into payment from public.payments where public.payments.id=(p_details->>'payment_id')::uuid and folio_id=f.id;
  if not found then raise exception 'Select a payment recorded on this folio.' using errcode='22023';end if;
  id:=public.refund_payment(payment.id,(p_details->>'amount')::numeric,p_details->>'reason');
 elsif p_action='invoice' then id:=public.finalize_invoice(f.id);
 else raise exception 'Unknown billing action.' using errcode='22023';end if;
 insert into public.billing_events(tenant_id,property_id,reservation_id,request_id,action,payload,result_id,actor_id) values(r.tenant_id,r.property_id,r.id,p_request,p_action,p_details,id,auth.uid());
 return jsonb_build_object('id',id,'action',p_action);
end $$;

create or replace function public.reservation_detail(p_property uuid,p_id uuid) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare r public.reservations;result jsonb;can_fin boolean;f public.folios;posted numeric;paid numeric;refunded numeric;room_posted numeric;credited numeric;
begin
 if not private.has_permission(p_property,'reservations.read') then raise exception 'not permitted' using errcode='42501';end if;
 select * into r from public.reservations where id=p_id and property_id=p_property;
 if not found then raise exception 'Reservation not found.' using errcode='P0002';end if;
 can_fin:=private.has_permission(p_property,'finance.read') or private.has_permission(p_property,'billing.manage');
 result:=jsonb_build_object('stay',to_jsonb(r),'guest',(select to_jsonb(g) from public.guests g where id=r.guest_id),
 'room',(select jsonb_build_object('id',u.id,'name',u.name,'type_id',u.type_id,'type_name',t.name,'housekeeping_status',u.housekeeping_status,'active',u.active) from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id join public.accommodation_types t on t.id=u.type_id where h.reservation_id=r.id order by h.active desc,h.created_at desc limit 1),
 'events',coalesce((select jsonb_agg(to_jsonb(x)) from(select event_type,created_at,details from public.reservation_events where reservation_id=r.id order by created_at desc,id desc limit 30)x),'[]'::jsonb),
 'can_write',private.has_permission(p_property,'reservations.write'),'can_frontdesk',private.has_permission(p_property,'frontdesk.manage'),
 'can_bill',private.has_permission(p_property,'billing.manage'),'can_finance',can_fin,'can_portal',private.has_permission(p_property,'guest_requests.manage'));
 if can_fin then
  select * into f from public.folios where reservation_id=r.id;
  select coalesce(sum(amount),0),coalesce(sum(amount) filter(where kind='room'),0) into posted,room_posted from public.folio_items where folio_id=f.id;
  select coalesce(sum(amount),0) into paid from public.payments where folio_id=f.id;
  select coalesce(sum(rf.amount),0) into refunded from public.refunds rf join public.payments py on py.id=rf.payment_id where py.folio_id=f.id;
  select coalesce(sum(amount),0) into credited from public.credit_notes where folio_id=f.id;
  result:=result||jsonb_build_object('finance',jsonb_build_object('folio_id',f.id,'folio_status',f.status,'posted',posted,'paid',paid,'refunded',refunded,'credited',credited,'balance',posted-paid+refunded-credited,'unposted_room',case when r.status in ('confirmed','checked_in') then greatest(0,r.total_amount-room_posted) else 0 end,'checkout_balance',posted-paid+refunded-credited+case when r.status in ('confirmed','checked_in') then greatest(0,r.total_amount-room_posted) else 0 end));
 end if;
 return result;
end $$;

create or replace function public.billing_export(p_property uuid,p_reservation uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare f public.folios;currency text;result jsonb;
begin
 if not(private.has_permission(p_property,'finance.read') or private.has_permission(p_property,'billing.manage')) then raise exception 'not permitted' using errcode='42501';end if;
 select r.currency into currency from public.reservations r where r.id=p_reservation and r.property_id=p_property;
 if not found then raise exception 'Folio not found in this hotel.' using errcode='P0002';end if;
 select * into f from public.folios where reservation_id=p_reservation;
 if(select count(*) from private.billing_ledger(f.id))>10000 then raise exception 'This folio exceeds the export limit of 10,000 entries.' using errcode='54000';end if;
 select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',x.amount::text,'running_balance',x.running_balance::text) order by x.created_at,x.entry_order),'[]'::jsonb) into result from(select *,sum(amount) over(order by created_at,entry_order,id) as running_balance from private.billing_ledger(f.id))x;
 return jsonb_build_object('currency',currency,'entries',result);
end $$;
