-- Serialize final upload confirmation with reservation checkout and cancellation.
create or replace function public.portal_confirm_document(p_token text,p_doc uuid)returns void language plpgsql security definer set search_path=''as $$
declare r public.reservations;d public.guest_documents;
begin
 r:=private.portal_reservation(p_token);
 perform pg_advisory_xact_lock(hashtextextended('portal-reservation:'||r.id::text,0));
 select * into r from public.reservations where id=r.id for update;
 if r.status not in('confirmed','checked_in')then raise exception 'Document uploads are closed for this stay.'using errcode='22023';end if;
 select * into d from public.guest_documents where id=p_doc and reservation_id=r.id for update;
 if not found then raise exception 'Document not found for this stay.'using errcode='22023';end if;
 if d.status='pending_upload'then update public.guest_documents set status='uploaded',uploaded_at=now()where id=d.id;end if;
end $$;
