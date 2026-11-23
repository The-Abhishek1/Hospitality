-- Scanner leases keep quarantined files private and prevent stale workers changing a result.
create table private.document_scan_leases(
 document_id uuid primary key references public.guest_documents(id)on delete cascade,
 lease_id uuid not null default gen_random_uuid(),expires_at timestamptz not null,
 retry_after timestamptz not null default now(),attempts integer not null default 1,last_error text
);
revoke all on private.document_scan_leases from public,anon,authenticated,service_role;
create function public.claim_document_scans(p_limit integer default 1)returns table(document_id uuid,lease_id uuid,storage_path text,size_bytes integer)
language plpgsql security definer set search_path=''as $$
declare d public.guest_documents;lease uuid;
begin
 for d in select x.*from public.guest_documents x join public.properties p on p.id=x.property_id left join private.document_scan_leases l on l.document_id=x.id where x.status='uploaded'and p.archived_at is null and private.tenant_is_active(x.tenant_id)and(l.document_id is null or l.expires_at<now()and l.retry_after<=now())order by x.uploaded_at,x.id limit greatest(1,least(5,p_limit))for update of x skip locked loop
  insert into private.document_scan_leases(document_id,expires_at)values(d.id,now()+interval '3 minutes')on conflict on constraint document_scan_leases_pkey do update set lease_id=gen_random_uuid(),expires_at=now()+interval '3 minutes',attempts=document_scan_leases.attempts+1,last_error=null returning document_scan_leases.lease_id into lease;
  return query select d.id,lease,d.storage_path,d.size_bytes;
 end loop;
end $$;
create function public.complete_document_scan(p_document uuid,p_lease uuid,p_result text,p_error text default null)returns boolean
language plpgsql security definer set search_path=''as $$
declare d public.guest_documents;l private.document_scan_leases;
begin
 select *into d from public.guest_documents where id=p_document for update;
 select *into l from private.document_scan_leases where document_id=p_document and lease_id=p_lease and expires_at>now()for update;
 if d.status is distinct from 'uploaded'or l.document_id is null then return false;end if;
 if p_result in('clean','infected')then perform public.mark_document_scan(d.id,p_result);delete from private.document_scan_leases where document_id=d.id;
 elsif p_result='error'then update private.document_scan_leases set expires_at=now(),retry_after=now()+interval '10 minutes',last_error='Scanner unavailable or file could not be verified.'where document_id=d.id;
 else raise exception 'Unknown scan result.'using errcode='22023';end if;
 return true;
end $$;
revoke all on function public.claim_document_scans(integer),public.complete_document_scan(uuid,uuid,text,text)from public,anon,authenticated;
grant execute on function public.claim_document_scans(integer),public.complete_document_scan(uuid,uuid,text,text)to service_role;
create trigger archived_property_write before insert or update or delete on public.whatsapp_journey_settings for each row execute function private.guard_archived_property_write();
