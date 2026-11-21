create function public.portal_command(p_token text,p_request uuid,p_action text,p_payload jsonb default '{}')returns jsonb
language plpgsql security definer set search_path=''as $$
declare r public.reservations;cmd private.guest_portal_commands;result jsonb;id uuid;d public.guest_arrival_details;q public.guest_requests;f public.folios;rec record;ver integer;day date;expected numeric;actual numeric;field text;
begin
 r:=private.portal_reservation(p_token);
 if p_request is null or p_action is null or p_action not in('arrival','service','request_checkin','request_checkout','order','cancel_request','feedback')or p_payload is null or jsonb_typeof(p_payload)<>'object'or pg_column_size(p_payload)>24000 then raise exception 'Reload this form and try again.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('portal-reservation:'||r.id::text,0));
 select * into cmd from private.guest_portal_commands where reservation_id=r.id and request_id=p_request;
 if found then if cmd.action<>p_action or cmd.payload<>p_payload then raise exception 'This submission was already used for different details. Refresh before sending again.'using errcode='22023';end if;return cmd.result;end if;
 if(select count(*)from private.guest_portal_commands where reservation_id=r.id and created_at>now()-interval '1 hour')>=100 then raise exception 'Too many recent submissions. Please contact reception.'using errcode='54000';end if;
 -- Match the property -> reservation -> folio order used by hotel financial workflows.
 perform 1 from public.properties where public.properties.id=r.property_id for share;
 select * into r from public.reservations where public.reservations.id=r.id for update;
 if p_action<>'feedback'and r.status not in('confirmed','checked_in')then raise exception 'This stay is no longer open for changes. Please contact reception.'using errcode='22023';end if;
 select(now()at time zone timezone)::date into day from public.properties where public.properties.id=r.property_id;
 if p_action='arrival'then
  foreach field in array array['full_name','email','phone','country_code','address','arrival_time','arrival_notes']loop
   if jsonb_typeof(p_payload->field)is distinct from 'string'then raise exception 'Check the guest detail fields.'using errcode='22023';end if;
  end loop;
  if length(trim(p_payload->>'full_name'))not between 2 and 120 or length(p_payload->>'email')>254 or(p_payload->>'email'<>''and p_payload->>'email'!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')or(p_payload->>'phone'<>''and p_payload->>'phone'!~'^\+[1-9][0-9]{7,14}$')or(p_payload->>'country_code'<>''and p_payload->>'country_code'!~'^[A-Z]{2}$')or length(p_payload->>'address')>500 or length(p_payload->>'arrival_notes')>500 or(p_payload->>'arrival_time'<>''and p_payload->>'arrival_time'!~'^([01][0-9]|2[0-3]):[0-5][0-9]$')or jsonb_typeof(p_payload->'stay_updates_requested')is distinct from 'boolean'or coalesce(p_payload->>'version','')!~'^[0-9]{1,9}$'then raise exception 'Check your name, contact details, country and arrival time.'using errcode='22023';end if;
  if(p_payload->>'stay_updates_requested')::boolean and p_payload->>'phone'=''then raise exception 'Add your phone number to request stay updates.'using errcode='22023';end if;
  select * into d from public.guest_arrival_details where reservation_id=r.id;
  if coalesce(d.version,0)<>(p_payload->>'version')::integer then raise exception 'Your details changed in another session. Refresh and review them.'using errcode='40001';end if;
  insert into public.guest_arrival_details(reservation_id,tenant_id,property_id,full_name,email,phone,country_code,address,arrival_time,arrival_notes,stay_updates_requested)
  values(r.id,r.tenant_id,r.property_id,trim(p_payload->>'full_name'),trim(p_payload->>'email'),p_payload->>'phone',p_payload->>'country_code',trim(p_payload->>'address'),p_payload->>'arrival_time',trim(p_payload->>'arrival_notes'),(p_payload->>'stay_updates_requested')::boolean)
  on conflict(reservation_id)do update set full_name=excluded.full_name,email=excluded.email,phone=excluded.phone,country_code=excluded.country_code,address=excluded.address,arrival_time=excluded.arrival_time,arrival_notes=excluded.arrival_notes,stay_updates_requested=excluded.stay_updates_requested,version=guest_arrival_details.version+1,updated_at=now()returning version into ver;
  id:=r.id;result:=jsonb_build_object('id',id,'version',ver,'action',p_action);
 elsif p_action in('service','request_checkin','request_checkout')then
  if length(coalesce(p_payload->>'title',''))>200 or length(coalesce(p_payload->>'notes',''))>1000 then raise exception 'Keep the title under 200 characters and notes under 1000.'using errcode='22023';end if;
  if p_action='request_checkin'and(r.status<>'confirmed'or day<r.check_in or day>=r.check_out)then raise exception 'Check-in help can be requested during your booked arrival period. Contact reception for early arrival.'using errcode='22023';end if;
  if p_action='request_checkout'and r.status<>'checked_in'then raise exception 'Checkout assistance is available for checked-in stays.'using errcode='22023';end if;
  if p_action<>'service'then
   select a.guest_request_id into id from public.guest_stay_requests a join public.guest_requests g on g.id=a.guest_request_id where a.reservation_id=r.id and a.intent=case when p_action='request_checkin'then 'checkin'else 'checkout'end and g.status in('new','in_progress')order by g.created_at desc limit 1;
  end if;
  if id is null then
   if(select count(*)from public.guest_requests where reservation_id=r.id and created_at>now()-interval '1 hour')>=10 then raise exception 'Too many recent requests. Please contact reception.'using errcode='54000';end if;
   id:=private.create_guest_request_core(r.property_id,r.id,case when p_action='service'then nullif(p_payload->>'catalog_id','')::uuid end,case when p_action='service'then p_payload->>'title'when p_action='request_checkin'then 'Request check-in'else 'Request checkout'end,p_payload->>'notes','portal',null);
   if p_action<>'service'then insert into public.guest_stay_requests(tenant_id,property_id,reservation_id,guest_request_id,intent)values(r.tenant_id,r.property_id,r.id,id,case when p_action='request_checkin'then 'checkin'else 'checkout'end);end if;
  end if;
 elsif p_action='order'then
  if r.status<>'checked_in'then raise exception 'Room ordering opens after the hotel checks you in.'using errcode='22023';end if;
  if p_payload->>'currency'is distinct from r.currency::text then raise exception 'The hotel currency changed. Refresh the menu.'using errcode='40001';end if;
  if coalesce(p_payload->>'total','')!~'^[0-9]{1,10}(\.[0-9]{1,2})?$'or length(coalesce(p_payload->>'notes',''))>500 or jsonb_typeof(p_payload->'items')is distinct from 'array'or jsonb_array_length(p_payload->'items')not between 1 and 30 then raise exception 'Review your cart and notes before ordering.'using errcode='22023';end if;
  if(select count(*)from public.orders where reservation_id=r.id and created_at>now()-interval '1 hour')>=10 then raise exception 'Too many recent orders. Please contact reception.'using errcode='54000';end if;
  f:=private.billing_lock(r.id);if f.status<>'open'then raise exception 'Your room bill is closed. Please contact reception to order.'using errcode='22023';end if;
  perform mi.id from public.menu_items mi join jsonb_to_recordset(p_payload->'items')as x(menu_item_id uuid,version integer,quantity integer)on mi.id=x.menu_item_id where mi.property_id=r.property_id order by mi.id for share of mi;
  if exists(select 1 from jsonb_to_recordset(p_payload->'items')as x(menu_item_id uuid,version integer,quantity integer)left join public.menu_items mi on mi.id=x.menu_item_id and mi.property_id=r.property_id where mi.id is null or not mi.active or mi.version is distinct from x.version)then raise exception 'The menu changed. Refresh it and review your cart before ordering.'using errcode='40001';end if;
  expected:=(p_payload->>'total')::numeric;
  id:=private.place_order_core(r.property_id,'room_service',p_payload->'items',r.id,null,p_payload->>'notes',null);
  select total into actual from public.orders where public.orders.id=id;
  if actual<>expected then raise exception 'The order total changed. Refresh the menu and review the price.'using errcode='40001';end if;
 elsif p_action='cancel_request'then
  if coalesce(p_payload->>'id','')!~'^[0-9a-fA-F-]{36}$'or coalesce(p_payload->>'version','')!~'^[0-9]{1,9}$'then raise exception 'Refresh the request before cancelling.'using errcode='22023';end if;
  id:=(p_payload->>'id')::uuid;
  if not exists(select 1 from public.guest_requests where public.guest_requests.id=id and reservation_id=r.id)then raise exception 'Request not found for this stay.'using errcode='22023';end if;
  perform pg_advisory_xact_lock(hashtextextended('service-request:'||id::text,0));
  perform 1 from public.tasks where guest_request_id=id order by public.tasks.id for update;
  select * into q from public.guest_requests where public.guest_requests.id=id and reservation_id=r.id for update;
  if q.version<>(p_payload->>'version')::integer then raise exception 'The request changed. Refresh to see its current status.'using errcode='40001';end if;
  if q.status<>'new'or exists(select 1 from public.tasks where guest_request_id=id and status not in('open','cancelled'))then raise exception 'The team has started this request. Contact reception for changes.'using errcode='22023';end if;
  update public.guest_requests set status='cancelled',completed_at=null where public.guest_requests.id=id;
  for rec in update public.tasks set status='cancelled',completed_at=null,updated_at=now()where guest_request_id=id and status='open'returning * loop
   insert into public.task_events(tenant_id,property_id,task_id,event_type,actor_id,details)values(r.tenant_id,r.property_id,rec.id,'cancelled',null,jsonb_build_object('source','guest_portal'));end loop;
  insert into public.guest_request_events(tenant_id,property_id,guest_request_id,event_type,actor_id,details)values(r.tenant_id,r.property_id,id,'cancelled',null,jsonb_build_object('reason','Cancelled by guest before work started','source','guest_portal'));
 else
  if coalesce(p_payload->>'rating','')!~'^[1-5]$'or length(coalesce(p_payload->>'comment',''))>1000 then raise exception 'Choose 1–5 stars and a comment under 1000 characters.'using errcode='22023';end if;
  id:=(p_payload->>'id')::uuid;
  perform public.portal_submit_feedback(p_token,id,(p_payload->>'rating')::integer,p_payload->>'comment');
 end if;
 result:=coalesce(result,jsonb_build_object('id',id,'action',p_action));
 insert into private.guest_portal_commands(reservation_id,request_id,action,payload,result)values(r.id,p_request,p_action,p_payload,result);
 insert into public.guest_portal_events(tenant_id,property_id,reservation_id,action,details)values(r.tenant_id,r.property_id,r.id,p_action,jsonb_build_object('result_id',id,'version',ver,'source','guest_portal'));
 return result;
end $$;
revoke all on function public.portal_command(text,uuid,text,jsonb)from public,anon,authenticated;
grant execute on function public.portal_command(text,uuid,text,jsonb)to anon,authenticated;

-- Upload finalization is idempotent; it never reverses scan/review decisions.
create or replace function public.portal_confirm_document(p_token text,p_doc uuid)returns void language plpgsql security definer set search_path=''as $$
declare r public.reservations;d public.guest_documents;
begin
 r:=private.portal_reservation(p_token);
 if r.status not in('confirmed','checked_in')then raise exception 'Document uploads are closed for this stay.'using errcode='22023';end if;
 select * into d from public.guest_documents where id=p_doc and reservation_id=r.id for update;
 if not found then raise exception 'Document not found for this stay.'using errcode='22023';end if;
 if d.status='pending_upload'then update public.guest_documents set status='uploaded',uploaded_at=now()where id=d.id;end if;
end $$;
create function public.portal_upload_metadata(p_token text,p_doc uuid)returns jsonb language plpgsql security definer set search_path=''as $$
declare r public.reservations;result jsonb;
begin
 r:=private.portal_reservation(p_token);
 if r.status not in('confirmed','checked_in')then raise exception 'Document uploads are closed for this stay.'using errcode='22023';end if;
 select jsonb_build_object('storage_path',storage_path,'size_bytes',size_bytes,'mime_type',mime_type)into result from public.guest_documents where id=p_doc and reservation_id=r.id;
 if result is null then raise exception 'Document not found for this stay.'using errcode='22023';end if;return result;
end $$;
revoke all on function public.portal_upload_metadata(text,uuid)from public,anon,authenticated;
grant execute on function public.portal_upload_metadata(text,uuid)to service_role;
