-- One focused guest task at a time, served by the hotel's app.
create function private.portal_document_progress(p_reservation uuid)returns jsonb
language sql stable security definer set search_path=''as $$
 with progress as(select coalesce((select required_documents from public.whatsapp_journey_settings where property_id=r.property_id),1)required,
 count(*)filter(where d.status='approved')::integer approved,
 count(*)filter(where d.status in('uploaded','clean','approved'))::integer submitted,
 count(*)filter(where d.status in('uploaded','clean'))::integer pending,
 count(*)filter(where d.status in('rejected','infected'))::integer rejected
 from public.reservations r left join public.guest_documents d on d.reservation_id=r.id and d.doc_type in('id_proof','passport','visa')where r.id=p_reservation group by r.property_id)
 select jsonb_build_object('required',required,'approved',approved,'submitted',submitted,'can_upload',submitted<required,'state',case when approved>=required and pending=0 then'approved'when submitted>=required then'review'when rejected>0 then'replacement'else'upload'end)from progress
$$;
create function public.portal_task_workspace(p_token text,p_task text,p_filters jsonb default '{}')returns jsonb
language plpgsql security definer set search_path=''as $$
declare data jsonb;result jsonb;r public.reservations;k text;keys text[];progress jsonb;
begin
 if p_task is null or p_task not in('documents','food','bill','stay','services','arrival','guide','checkin','checkout')then raise exception 'Unknown guest task.'using errcode='22023';end if;
 data:=public.portal_workspace(p_token,p_filters);r:=private.portal_reservation(p_token);
 result:=jsonb_build_object('stay',data->'stay','property',data->'property','room',data->'room','journey',data->'journey','updated_at',data->'updated_at');
 keys:=case p_task when'documents'then array['documents']when'food'then array['menu','menu_categories','menu_total','menu_page','menu_page_size','orders','order_total']when'bill'then array['bill']when'services'then array['services','requests','request_total']when'arrival'then array['arrival','guest']when'guide'then array['links']when'checkin'then array['stay_requests']when'checkout'then array['stay_requests']else array[]::text[]end;
 foreach k in array keys loop result:=result||jsonb_build_object(k,data->k);end loop;
 result:=result||jsonb_build_object('capabilities',case p_task when'documents'then jsonb_build_object('documents',data#>'{capabilities,documents}')when'food'then jsonb_build_object('order',data#>'{capabilities,order}')when'services'then jsonb_build_object('requests',data#>'{capabilities,requests}')when'arrival'then jsonb_build_object('details',data#>'{capabilities,details}')when'checkin'then jsonb_build_object('checkin',data#>'{capabilities,checkin}')when'checkout'then jsonb_build_object('checkout',data#>'{capabilities,checkout}')else'{}'::jsonb end);
 if p_task='documents'then progress:=private.portal_document_progress(r.id);result:=result||jsonb_build_object('document_state',progress);end if;
 return result;
end $$;
revoke all on function private.portal_document_progress(uuid)from public,anon,authenticated,service_role;
revoke all on function public.portal_task_workspace(text,text,jsonb)from public;
grant execute on function public.portal_task_workspace(text,text,jsonb)to anon,authenticated;

alter function public.portal_prepare_document(text,text,text,integer)rename to portal_prepare_document_before_focused;
revoke all on function public.portal_prepare_document_before_focused(text,text,text,integer)from public,anon,authenticated,service_role;
create function public.portal_prepare_document(p_token text,p_doc_type text,p_mime text,p_size integer)returns jsonb
language plpgsql security definer set search_path=''as $$
declare r public.reservations;progress jsonb;
begin
 r:=private.portal_reservation(p_token);perform pg_advisory_xact_lock(hashtextextended('portal-reservation:'||r.id::text,0));perform 1 from public.reservations where id=r.id for update;
 if p_doc_type in('id_proof','passport','visa')then
  progress:=private.portal_document_progress(r.id);
  if not(progress->>'can_upload')::boolean then raise exception 'Your identity documents are already received or approved. A replacement upload opens only if the hotel rejects a document.'using errcode='22023';end if;
 end if;
 return public.portal_prepare_document_before_focused(p_token,p_doc_type,p_mime,p_size);
end $$;
revoke all on function public.portal_prepare_document(text,text,text,integer)from public,anon,authenticated;
grant execute on function public.portal_prepare_document(text,text,text,integer)to service_role;

-- Security-rejected files use the same replacement workflow as hotel rejections.
create or replace function private.whatsapp_domain_event()returns trigger language plpgsql security definer set search_path=''as $$
declare d jsonb:=to_jsonb(new);prev jsonb;ev text;rid uuid;details jsonb:='{}';dedup text;related public.guest_requests;pid uuid:=(d->>'property_id')::uuid;sid uuid:=(d->>'id')::uuid;st text:=d->>'status';
begin
 if tg_op='UPDATE'then prev:=to_jsonb(old);end if;
 if tg_table_name='reservations'then
  rid:=sid;
  if tg_op='INSERT'then if st='confirmed'then ev:='booking_confirmed';end if;
  elsif st is distinct from prev->>'status'then ev:=case st when'confirmed'then'booking_confirmed'when'checked_in'then'checked_in'when'checked_out'then'checked_out'when'cancelled'then'booking_cancelled'end;
  elsif(d->>'check_in',d->>'check_out')is distinct from(prev->>'check_in',prev->>'check_out')then ev:='booking_changed';end if;
 elsif tg_table_name='unit_holds'then
  if d->>'kind'='reservation'and(d->>'reservation_id')is not null and(tg_op='INSERT'or d->>'unit_id'is distinct from prev->>'unit_id')and exists(select 1 from public.reservations where id=(d->>'reservation_id')::uuid and created_at<now())then rid:=(d->>'reservation_id')::uuid;ev:='booking_changed';st:='active';end if;
 elsif tg_table_name='orders'then
  rid:=(d->>'reservation_id')::uuid;
  if tg_op='INSERT'or st is distinct from prev->>'status'then ev:=case st when'placed'then'order_placed'when'preparing'then'order_preparing'when'ready'then'order_ready'when'served'then'order_served'when'cancelled'then'order_cancelled'end;end if;
  details:=jsonb_build_object('order_reference',upper(left(replace(sid::text,'-',''),8)));
 elsif tg_table_name='guest_requests'then
  rid:=(d->>'reservation_id')::uuid;
  if tg_op='INSERT'or st is distinct from prev->>'status'then ev:=case st when'new'then'request_received'when'in_progress'then'request_started'when'completed'then'request_completed'when'cancelled'then'request_cancelled'end;end if;
  details:=jsonb_build_object('request_title',d->>'title');
  if ev='request_completed'then dedup:='request:'||sid::text||':completed';end if;
 elsif tg_table_name='tasks'then
  if tg_op='UPDATE'and st='done'and st is distinct from prev->>'status'and d->>'guest_request_id'is not null then
   select *into related from public.guest_requests where id=(d->>'guest_request_id')::uuid and property_id=pid;
   rid:=related.reservation_id;ev:='request_completed';dedup:='request:'||related.id::text||':completed';details:=jsonb_build_object('request_title',related.title);
  end if;
 elsif tg_table_name='payments'then
  select reservation_id into rid from public.folios where id=(d->>'folio_id')::uuid and property_id=pid;
  if rid is null then select reservation_id into rid from public.orders where id=(d->>'order_id')::uuid and property_id=pid;end if;
  ev:='payment_received';details:=jsonb_build_object('amount',d->>'amount');
 elsif tg_table_name='refunds'then
  select coalesce(f.reservation_id,o.reservation_id)into rid from public.payments pay left join public.folios f on f.id=pay.folio_id left join public.orders o on o.id=pay.order_id where pay.id=(d->>'payment_id')::uuid and pay.property_id=pid;
  ev:='payment_refunded';details:=jsonb_build_object('amount',d->>'amount');
 elsif tg_table_name='invoices'then
  select reservation_id into rid from public.folios where id=(d->>'folio_id')::uuid and property_id=pid;
  ev:='invoice_issued';details:=jsonb_build_object('invoice_number',d->>'number','amount',d->>'total');
 elsif tg_table_name='guest_documents'then
  rid:=(d->>'reservation_id')::uuid;
  if tg_op='UPDATE'and st is distinct from prev->>'status'then ev:=case st when'uploaded'then'documents_received'when'approved'then'documents_approved'when'rejected'then'documents_rejected'when'infected'then'documents_rejected'end;end if;
 end if;
 if ev is not null and rid is not null then
  -- Stable per-object milestones; modifications deduplicate within a transaction.
  dedup:=coalesce(dedup,case when ev='booking_changed'then'stay:'||rid::text||':changed:'||txid_current()::text else tg_table_name||':'||sid::text||':'||ev end);
  perform private.capture_whatsapp_event(pid,rid,ev,dedup,tg_table_name,sid,st,details);
 end if;
 return new;
end $$;
