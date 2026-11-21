-- Enforce stay lifecycle and document limits across concurrent guest links.
create or replace function public.portal_prepare_document(p_token text, p_doc_type text, p_mime text, p_size int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r public.reservations; v_id uuid := gen_random_uuid(); v_path text;
begin
  r := private.portal_reservation(p_token);
  perform pg_advisory_xact_lock(hashtextextended('portal-reservation:'||r.id::text,0));
  select * into r from public.reservations where id=r.id for update;
  if r.status not in('confirmed','checked_in')then raise exception 'Document uploads are closed for this stay.'using errcode='22023';end if;
  if p_mime not in ('image/jpeg', 'image/png', 'application/pdf') then raise exception 'unsupported file type' using errcode = '22023'; end if;
  if p_size is null or p_size < 1 or p_size > 10485760 then raise exception 'file size must be between 1 byte and 10 MB' using errcode = '22023'; end if;
  if (select count(*) from public.guest_documents where reservation_id = r.id) >= 10 then raise exception 'document limit reached' using errcode = '54000'; end if;
  v_path := r.tenant_id || '/' || r.property_id || '/' || r.id || '/' || v_id;
  insert into public.guest_documents (id, tenant_id, property_id, reservation_id, guest_id, doc_type, storage_path, mime_type, size_bytes)
  values (v_id, r.tenant_id, r.property_id, r.id, r.guest_id, p_doc_type, v_path, p_mime, p_size);
  return jsonb_build_object('document_id', v_id, 'storage_path', v_path);
end $$;
