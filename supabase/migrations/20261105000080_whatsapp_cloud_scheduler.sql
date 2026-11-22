-- Invocation secret is encrypted in Supabase Vault; no service-role key appears in cron SQL.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
create table private.whatsapp_worker_configuration(
 id boolean primary key default true check(id),origin text not null,secret_id uuid not null,enabled boolean not null default false,
 last_started_at timestamptz,last_finished_at timestamptz,last_success_at timestamptz,last_result text
);
revoke all on private.whatsapp_worker_configuration from public,anon,authenticated,service_role;
create function public.configure_whatsapp_cloud_worker(p_origin text,p_secret text,p_enabled boolean)returns void
language plpgsql security definer set search_path=''as $$
declare sid uuid;
begin
 if p_origin is null or p_origin!~'^https://[a-z0-9]{20}\.supabase\.co$'or p_secret is null or p_secret!~'^[a-f0-9]{64}$'or p_enabled is null then raise exception 'Invalid worker configuration'using errcode='22023';end if;
 select secret_id into sid from private.whatsapp_worker_configuration where id=true for update;
 if sid is null then sid:=vault.create_secret(p_secret,'hospitality_whatsapp_worker_secret');else perform vault.update_secret(sid,p_secret);end if;
 insert into private.whatsapp_worker_configuration(id,origin,secret_id,enabled)values(true,p_origin,sid,p_enabled)
 on conflict(id)do update set origin=excluded.origin,secret_id=excluded.secret_id,enabled=excluded.enabled;
end $$;
create function private.invoke_whatsapp_cloud_worker()returns bigint
language plpgsql security definer set search_path=''as $$
declare c private.whatsapp_worker_configuration;token text;request_id bigint;
begin
 select *into c from private.whatsapp_worker_configuration where id=true and enabled;if c.id is null then return null;end if;
 select decrypted_secret into token from vault.decrypted_secrets where id=c.secret_id;
 select net.http_post(url:=c.origin||'/functions/v1/whatsapp-worker',headers:=jsonb_build_object('Content-Type','application/json','X-Worker-Secret',token),body:='{}',timeout_milliseconds:=120000)into request_id;
 return request_id;
end $$;
create function public.record_whatsapp_worker_health(p_stage text,p_ok boolean default true)returns void
language plpgsql security definer set search_path=''as $$
begin
 if p_stage='started'then update private.whatsapp_worker_configuration set last_started_at=now()where id=true;
 elsif p_stage='finished'then update private.whatsapp_worker_configuration set last_finished_at=now(),last_success_at=case when p_ok then now()else last_success_at end,last_result=case when p_ok then'ok'else'error'end where id=true;end if;
end $$;
revoke all on function public.configure_whatsapp_cloud_worker(text,text,boolean),public.record_whatsapp_worker_health(text,boolean),private.invoke_whatsapp_cloud_worker()from public,anon,authenticated;
grant execute on function public.configure_whatsapp_cloud_worker(text,text,boolean),public.record_whatsapp_worker_health(text,boolean)to service_role;
select cron.schedule('hospitality-whatsapp-worker','* * * * *','select private.invoke_whatsapp_cloud_worker()');

alter function public.whatsapp_automation_workspace(uuid,integer)rename to whatsapp_automation_workspace_without_worker;
revoke all on function public.whatsapp_automation_workspace_without_worker(uuid,integer)from public,anon,authenticated;
create function public.whatsapp_automation_workspace(p_property uuid,p_page integer default 1)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare result jsonb;
begin
 result:=public.whatsapp_automation_workspace_without_worker(p_property,p_page);
 return result||jsonb_build_object('worker',(select jsonb_build_object('enabled',enabled,'last_started_at',last_started_at,'last_finished_at',last_finished_at,'last_success_at',last_success_at,'last_result',last_result)from private.whatsapp_worker_configuration where id=true));
end $$;
revoke all on function public.whatsapp_automation_workspace(uuid,integer)from public,anon;
grant execute on function public.whatsapp_automation_workspace(uuid,integer)to authenticated;
