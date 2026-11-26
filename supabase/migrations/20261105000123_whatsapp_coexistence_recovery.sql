-- Recover leases even when an interrupted job is the last work in the queue.
-- Single-use Meta requests become unknown; only local imports can be reclaimed.
create or replace function private.invoke_whatsapp_coexistence_worker()returns bigint
language plpgsql security definer set search_path=''as $$
declare c private.whatsapp_worker_configuration;secret text;request bigint;
begin
 update private.whatsapp_coexistence_sync set state='unknown',can_retry=false,error='The sync request outcome is unconfirmed. Check Meta before reconnecting; it was not sent again.'where state='sending'and claimed_at<now()-interval '3 minutes';
 update private.whatsapp_coexistence_events set state=case when attempts>=5 then'failed'else'pending'end,error='Import interrupted; already recorded messages remain deduplicated.'where state='processing'and claimed_at<now()-interval '3 minutes';
 select *into c from private.whatsapp_worker_configuration where id=true and enabled;if c.id is null then return null;end if;
 if not exists(select 1 from private.whatsapp_coexistence_sync where state='pending')and not exists(select 1 from private.whatsapp_coexistence_events where state='pending')then return null;end if;
 select decrypted_secret into secret from vault.decrypted_secrets where id=c.secret_id;
 select net.http_post(url:=c.origin||'/functions/v1/whatsapp-coexistence-worker',headers:=jsonb_build_object('Content-Type','application/json','X-Worker-Secret',secret),body:='{}',timeout_milliseconds:=120000)into request;
 return request;
end $$;
