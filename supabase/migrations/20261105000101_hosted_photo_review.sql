-- Photo rebuilding is a separate review path, never an antivirus verdict.
alter table public.whatsapp_journey_settings add column document_review_mode text not null default 'photo'check(document_review_mode in('photo','antivirus'));
alter table public.guest_documents add column review_method text not null default 'antivirus'check(review_method in('photo','antivirus'));
alter table public.guest_documents drop constraint guest_documents_status_check;
alter table public.guest_documents add constraint guest_documents_status_check check(status in('pending_upload','uploaded','clean','infected','approved','rejected','image_ready','image_invalid'));
create table private.document_image_jobs(document_id uuid primary key references public.guest_documents(id)on delete cascade,lease_id uuid not null,expires_at timestamptz not null,attempts integer not null default 1,last_error text);
create table private.document_image_previews(document_id uuid primary key references public.guest_documents(id)on delete cascade,storage_path text not null unique,size_bytes integer not null check(size_bytes between 1 and 10485760),width integer not null check(width between 1 and 3000),height integer not null check(height between 1 and 3000),sha256 text not null check(sha256~'^[a-f0-9]{64}$'),validated_at timestamptz not null default now());
revoke all on private.document_image_jobs,private.document_image_previews from public,anon,authenticated,service_role;

alter function public.save_whatsapp_journey(uuid,integer,boolean,integer,boolean)rename to save_whatsapp_journey_before_photo;
revoke all on function public.save_whatsapp_journey_before_photo(uuid,integer,boolean,integer,boolean)from public,anon,authenticated,service_role;
create function public.save_whatsapp_journey(p_property uuid,p_version integer,p_enabled boolean,p_documents integer,p_self_checkin boolean,p_review_mode text default 'photo')returns void
language plpgsql security definer set search_path=''as $$
begin
 if p_review_mode is null or p_review_mode not in('photo','antivirus')then raise exception 'Choose photo-only review or antivirus scanning.'using errcode='22023';end if;
 perform public.save_whatsapp_journey_before_photo(p_property,p_version,p_enabled,p_documents,p_self_checkin);
 update public.whatsapp_journey_settings set document_review_mode=p_review_mode where property_id=p_property;
 insert into public.whatsapp_automation_audit(property_id,tenant_id,actor,action,details)select id,tenant_id,auth.uid(),'document_review_mode',jsonb_build_object('mode',p_review_mode)from public.properties where id=p_property;
end $$;
revoke all on function public.save_whatsapp_journey(uuid,integer,boolean,integer,boolean,text)from public,anon;
grant execute on function public.save_whatsapp_journey(uuid,integer,boolean,integer,boolean,text)to authenticated;

alter function public.portal_prepare_document(text,text,text,integer)rename to portal_prepare_document_before_photo;
revoke all on function public.portal_prepare_document_before_photo(text,text,text,integer)from public,anon,authenticated,service_role;
create function public.portal_prepare_document(p_token text,p_doc_type text,p_mime text,p_size integer)returns jsonb
language plpgsql security definer set search_path=''as $$
declare r public.reservations;mode text;result jsonb;
begin
 r:=private.portal_reservation(p_token);
 select coalesce((select document_review_mode from public.whatsapp_journey_settings where property_id=r.property_id),'photo')into mode;
 if mode='photo'and(p_mime is null or p_mime not in('image/jpeg','image/png'))then raise exception 'Photo-only review accepts JPG or PNG. PDF documents are disabled for this hotel.'using errcode='22023';end if;
 result:=public.portal_prepare_document_before_photo(p_token,p_doc_type,p_mime,p_size);
 update public.guest_documents set review_method=mode where id=(result->>'document_id')::uuid;
 return result||jsonb_build_object('review_method',mode);
end $$;
revoke all on function public.portal_prepare_document(text,text,text,integer)from public,anon,authenticated;
grant execute on function public.portal_prepare_document(text,text,text,integer)to service_role;

create function public.claim_document_image(p_document uuid,p_token text default null)returns jsonb
language plpgsql security definer set search_path=''as $$
declare r public.reservations;d public.guest_documents;j private.document_image_jobs;lease uuid;mode text;
begin
 if p_token is not null then r:=private.portal_reservation(p_token);end if;
 select *into d from public.guest_documents where id=p_document for update;
 if d.id is null or(p_token is not null and d.reservation_id<>r.id)then raise exception 'Document unavailable for this stay.'using errcode='22023';end if;
 perform private.staff_share(d.property_id);
 if p_token is not null and r.status not in('confirmed','checked_in')then raise exception 'Document uploads are closed for this stay.'using errcode='22023';end if;
 if d.review_method='photo'and d.status in('image_ready','approved','rejected','image_invalid')then return jsonb_build_object('done',true,'status',d.status);end if;
 mode:=coalesce((select document_review_mode from public.whatsapp_journey_settings where property_id=d.property_id),'photo');
 if mode='antivirus'and d.review_method='antivirus'then return jsonb_build_object('mode','antivirus');end if;
 if d.status<>'uploaded'or d.mime_type not in('image/jpeg','image/png')then raise exception 'Only uploaded JPG/PNG files can be prepared for photo review.'using errcode='22023';end if;
 if exists(select 1 from private.document_scan_leases where document_id=d.id and expires_at>now())then raise exception 'This file is already being scanned. Retry shortly.'using errcode='40001';end if;
 select *into j from private.document_image_jobs where document_id=d.id;
 if j.document_id is not null and j.expires_at>now()then return jsonb_build_object('processing',true);end if;
 lease:=gen_random_uuid();
 insert into private.document_image_jobs(document_id,lease_id,expires_at)values(d.id,lease,now()+interval '2 minutes')on conflict(document_id)do update set lease_id=excluded.lease_id,expires_at=excluded.expires_at,attempts=document_image_jobs.attempts+1,last_error=null;
 update public.guest_documents set review_method='photo'where id=d.id;
 return jsonb_build_object('document_id',d.id,'lease_id',lease,'storage_path',d.storage_path,'preview_path',d.storage_path||'.preview.'||lease::text||'.jpg','size_bytes',d.size_bytes,'mime_type',d.mime_type);
end $$;
create function public.complete_document_image(p_document uuid,p_lease uuid,p_result text,p_size integer default null,p_width integer default null,p_height integer default null,p_sha256 text default null)returns boolean
language plpgsql security definer set search_path=''as $$
declare d public.guest_documents;j private.document_image_jobs;
begin
 select *into d from public.guest_documents where id=p_document for update;
 select *into j from private.document_image_jobs where document_id=p_document and lease_id=p_lease and expires_at>now()for update;
 if d.status is distinct from 'uploaded'or d.review_method<>'photo'or j.document_id is null then return false;end if;
 if p_result='ready'then
  if p_size is null or p_size not between 1 and 10485760 or p_width is null or p_width not between 1 and 3000 or p_height is null or p_height not between 1 and 3000 or p_sha256 is null or p_sha256!~'^[a-f0-9]{64}$'then raise exception 'Invalid rebuilt image metadata.'using errcode='22023';end if;
  insert into private.document_image_previews(document_id,storage_path,size_bytes,width,height,sha256)values(d.id,d.storage_path||'.preview.'||p_lease::text||'.jpg',p_size,p_width,p_height,p_sha256)on conflict(document_id)do update set storage_path=excluded.storage_path,size_bytes=excluded.size_bytes,width=excluded.width,height=excluded.height,sha256=excluded.sha256,validated_at=now();
  update public.guest_documents set status='image_ready'where id=d.id;
 elsif p_result='invalid'then update public.guest_documents set status='image_invalid'where id=d.id;
 elsif p_result='retry'then update private.document_image_jobs set expires_at=now(),last_error='Photo preparation unavailable. Retry.'where document_id=d.id;return true;
 else raise exception 'Unknown photo preparation result.'using errcode='22023';end if;
 delete from private.document_image_jobs where document_id=d.id;return true;
end $$;
revoke all on function public.claim_document_image(uuid,text),public.complete_document_image(uuid,uuid,text,integer,integer,integer,text)from public,anon,authenticated;
grant execute on function public.claim_document_image(uuid,text),public.complete_document_image(uuid,uuid,text,integer,integer,integer,text)to service_role;

create function public.document_photo_prepare_access(p_document uuid,p_reason text)returns boolean
language plpgsql security definer set search_path=''as $$
declare d public.guest_documents;
begin
 select *into d from public.guest_documents where id=p_document;
 if d.id is null or not private.has_permission(d.property_id,'documents.review')then raise exception 'Document-review access required.'using errcode='42501';end if;
 perform private.staff_share(d.property_id);
 if length(trim(coalesce(p_reason,'')))not between 10 and 1000 then raise exception 'Enter a review reason of 10–1000 characters.'using errcode='22023';end if;
 if coalesce((select document_review_mode from public.whatsapp_journey_settings where property_id=d.property_id),'photo')<>'photo'then raise exception 'This hotel uses antivirus scanning.'using errcode='22023';end if;
 insert into public.document_access_events(tenant_id,property_id,document_id,accessed_by,reason)values(d.tenant_id,d.property_id,d.id,auth.uid(),'Photo preparation: '||trim(p_reason));return true;
end $$;
revoke all on function public.document_photo_prepare_access(uuid,text)from public,anon;
grant execute on function public.document_photo_prepare_access(uuid,text)to authenticated;

create or replace function public.authorize_document_access(p_doc uuid,p_reason text)returns text
language plpgsql security definer set search_path=''as $$
declare d public.guest_documents;path text;
begin
 select *into d from public.guest_documents where id=p_doc;
 if d.id is null or not private.has_permission(d.property_id,'documents.review')then raise exception 'not permitted'using errcode='42501';end if;
 if coalesce(trim(p_reason),'')=''then raise exception 'a reason is required'using errcode='22023';end if;
 if d.review_method='photo'then
  if d.status not in('image_ready','approved','rejected')then raise exception 'Rebuilt photo is not ready for review.'using errcode='22023';end if;
  select storage_path into path from private.document_image_previews where document_id=d.id;
  if path is null then raise exception 'Rebuilt photo is unavailable.'using errcode='22023';end if;
 else
  if d.status not in('clean','approved','rejected')then raise exception 'document is not available (status %)',d.status using errcode='22023';end if;path:=d.storage_path;
 end if;
 insert into public.document_access_events(tenant_id,property_id,document_id,accessed_by,reason)values(d.tenant_id,d.property_id,d.id,auth.uid(),p_reason);return path;
end $$;
create or replace function public.review_document(p_doc uuid,p_decision text,p_note text default null)returns void
language plpgsql security definer set search_path=''as $$
declare d public.guest_documents;
begin
 select *into d from public.guest_documents where id=p_doc for update;
 if d.id is null or not private.has_permission(d.property_id,'documents.review')then raise exception 'not permitted'using errcode='42501';end if;
 if p_decision is null or p_decision not in('approved','rejected')then raise exception 'Choose approve or request replacement.'using errcode='22023';end if;
 if not(d.review_method='antivirus'and d.status='clean'or d.review_method='photo'and d.status='image_ready'and exists(select 1 from private.document_image_previews where document_id=d.id))then raise exception 'This document has not completed its configured file checks.'using errcode='22023';end if;
 insert into public.document_reviews(tenant_id,property_id,document_id,decision,note,reviewed_by)values(d.tenant_id,d.property_id,d.id,p_decision,p_note,auth.uid());update public.guest_documents set status=p_decision where id=d.id;
end $$;

create or replace function public.claim_document_scans(p_limit integer default 1)returns table(document_id uuid,lease_id uuid,storage_path text,size_bytes integer)
language plpgsql security definer set search_path=''as $$
declare d public.guest_documents;lease uuid;
begin
 for d in select x.*from public.guest_documents x join public.properties p on p.id=x.property_id left join private.document_scan_leases l on l.document_id=x.id where x.status='uploaded'and x.review_method='antivirus'and p.archived_at is null and private.tenant_is_active(x.tenant_id)and(l.document_id is null or l.expires_at<now()and l.retry_after<=now())order by x.uploaded_at,x.id limit greatest(1,least(5,p_limit))for update of x skip locked loop
  insert into private.document_scan_leases(document_id,expires_at)values(d.id,now()+interval '3 minutes')on conflict on constraint document_scan_leases_pkey do update set lease_id=gen_random_uuid(),expires_at=now()+interval '3 minutes',attempts=document_scan_leases.attempts+1,last_error=null returning document_scan_leases.lease_id into lease;
  return query select d.id,lease,d.storage_path,d.size_bytes;
 end loop;
end $$;

create or replace function private.portal_document_progress(p_reservation uuid)returns jsonb
language sql stable security definer set search_path=''as $$
 with progress as(select coalesce((select required_documents from public.whatsapp_journey_settings where property_id=r.property_id),1)required,
 count(*)filter(where d.status='approved')::integer approved,
 count(*)filter(where d.status in('uploaded','clean','image_ready','approved'))::integer submitted,
 count(*)filter(where d.status in('uploaded','clean','image_ready'))::integer pending,
 count(*)filter(where d.status in('rejected','infected','image_invalid'))::integer rejected
 from public.reservations r left join public.guest_documents d on d.reservation_id=r.id and d.doc_type in('id_proof','passport','visa')where r.id=p_reservation group by r.property_id)
 select jsonb_build_object('required',required,'approved',approved,'submitted',submitted,'can_upload',submitted<required,'state',case when approved>=required and pending=0 then'approved'when submitted>=required then'review'when rejected>0 then'replacement'else'upload'end)from progress
$$;

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
  if tg_op='UPDATE'and st is distinct from prev->>'status'then ev:=case st when'uploaded'then'documents_received'when'approved'then'documents_approved'when'rejected'then'documents_rejected'when'infected'then'documents_rejected'when'image_invalid'then'documents_rejected'end;end if;
 end if;
 if ev is not null and rid is not null then
  -- Stable per-object milestones; modifications deduplicate within a transaction.
  dedup:=coalesce(dedup,case when ev='booking_changed'then'stay:'||rid::text||':changed:'||txid_current()::text else tg_table_name||':'||sid::text||':'||ev end);
  perform private.capture_whatsapp_event(pid,rid,ev,dedup,tg_table_name,sid,st,details);
 end if;
 return new;
end $$;


create or replace function private.journey_document_error(p_reservation uuid)returns text language sql stable security definer set search_path='' as $$
 select case when count(*)filter(where d.status='approved'and d.doc_type in('id_proof','passport','visa'))<s.required_documents then 'Required identity documents must be approved by the hotel before check-in.'
 when count(*)filter(where d.status in('uploaded','clean','image_ready'))>0 then 'Finish reviewing the uploaded identity documents before check-in.'end
 from public.reservations r join public.whatsapp_journey_settings s on s.property_id=r.property_id and s.enabled
 left join public.guest_documents d on d.reservation_id=r.id where r.id=p_reservation group by s.required_documents
$$;

alter function public.portal_workspace(text,jsonb)rename to portal_workspace_before_photo_policy;
revoke all on function public.portal_workspace_before_photo_policy(text,jsonb)from public,anon,authenticated,service_role;
create function public.portal_workspace(p_token text,p_filters jsonb default '{}')returns jsonb
language plpgsql security definer set search_path=''as $$
declare data jsonb;r public.reservations;mode text;
begin
 data:=public.portal_workspace_before_photo_policy(p_token,p_filters);r:=private.portal_reservation(p_token);
 mode:=coalesce((select document_review_mode from public.whatsapp_journey_settings where property_id=r.property_id),'photo');
 return data||jsonb_build_object('journey',coalesce(data->'journey','{}')||jsonb_build_object('document_review_mode',mode),'documents',coalesce((select jsonb_agg(jsonb_build_object('id',id,'doc_type',doc_type,'status',status,'review_method',review_method,'size_bytes',size_bytes,'created_at',created_at,'uploaded_at',uploaded_at)order by created_at desc)from public.guest_documents where reservation_id=r.id),'[]'::jsonb));
end $$;
revoke all on function public.portal_workspace(text,jsonb)from public;
grant execute on function public.portal_workspace(text,jsonb)to anon,authenticated;
alter function public.whatsapp_journey_workspace(uuid,uuid)rename to whatsapp_journey_workspace_before_photo_policy;
revoke all on function public.whatsapp_journey_workspace_before_photo_policy(uuid,uuid)from public,anon,authenticated,service_role;
create function public.whatsapp_journey_workspace(p_property uuid,p_reservation uuid default null)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare data jsonb;
begin
 data:=public.whatsapp_journey_workspace_before_photo_policy(p_property,p_reservation);
 return data||jsonb_build_object('documents',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'doc_type',d.doc_type,'status',d.status,'created_at',d.created_at,'review_method',d.review_method,'can_open',case when d.review_method='photo'then d.status in('image_ready','approved','rejected')and exists(select 1 from private.document_image_previews p where p.document_id=d.id)else d.status in('clean','approved','rejected')end)order by d.created_at desc)from public.guest_documents d where d.property_id=p_property and d.reservation_id=p_reservation and private.has_permission(p_property,'documents.review')),'[]'::jsonb));
end $$;
revoke all on function public.whatsapp_journey_workspace(uuid,uuid)from public,anon;
grant execute on function public.whatsapp_journey_workspace(uuid,uuid)to authenticated;

alter function public.mark_document_scan(uuid,text)rename to mark_document_scan_before_photo;
revoke all on function public.mark_document_scan_before_photo(uuid,text)from public,anon,authenticated,service_role;
create function public.mark_document_scan(p_doc uuid,p_result text)returns void
language plpgsql security definer set search_path=''as $$
begin
 if exists(select 1 from public.guest_documents where id=p_doc and review_method='photo')then raise exception 'Photo rebuilding is not an antivirus result.'using errcode='22023';end if;
 perform public.mark_document_scan_before_photo(p_doc,p_result);
end $$;
revoke all on function public.mark_document_scan(uuid,text)from public,anon,authenticated;
grant execute on function public.mark_document_scan(uuid,text)to service_role;
