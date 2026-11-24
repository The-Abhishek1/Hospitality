create or replace function public.claim_online_payment()returns jsonb language plpgsql security definer set search_path=''as $$
declare job public.hotel_payment_requests;
begin
 -- Expire requests that never reached the provider; uncertain creations remain blocked.
 update public.hotel_payment_requests set state='expired',reconcile_needed=false,updated_at=now()where state='pending'and not creation_started and lease is null and expires_at<=now();
 update public.hotel_payment_requests set lease=null,state=case when state='creating'then'unknown'else state end,reconcile_needed=true,next_check_at=now()where locked_at<now()-interval '2 minutes'and lease is not null;
 select *into job from public.hotel_payment_requests where reconcile_needed and next_check_at<=now()and lease is null and state in('pending','unknown','ready','cancel_pending','paid','expired','cancelled')order by next_check_at,id limit 1 for update skip locked;
 if job.id is null then return null;end if;
 update public.hotel_payment_requests set lease=gen_random_uuid(),locked_at=now(),attempts=attempts+1,creation_started=creation_started or state='pending',state=case when state='pending'then'creating'else state end where id=job.id returning *into job;
 return to_jsonb(job)||jsonb_build_object('operation',case when job.state='creating'then'create'when job.state='cancel_pending'then'cancel'else'reconcile'end,'reference',replace(job.id::text,'-',''),'credential',(select ciphertext from private.hotel_payment_credentials where connection_id=job.connection_id));
end $$;
