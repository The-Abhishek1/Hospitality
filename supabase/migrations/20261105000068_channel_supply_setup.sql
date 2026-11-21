-- Provider preparation is separate from operator-approved sandbox traffic. No live OTA activation here.
alter table public.channel_connections drop constraint channel_connections_provider_check;
alter table public.channel_connections add constraint channel_connections_provider_check check(provider in ('mock','agoda','booking_com','makemytrip'));
alter table public.channel_connections add column external_property_id text check(external_property_id ~ '^[1-9][0-9]{0,19}$');
alter table public.channel_connections add column environment text not null default 'sandbox' check(environment='sandbox');
alter table public.channel_connections add column sandbox_approved boolean not null default false;
alter table public.sync_jobs add column lease_token uuid;

create function public.prepare_channel(p_property uuid,p_provider text,p_external_property_id text,p_credentials_ref text default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_tenant uuid; v_id uuid;
begin
 if not private.has_permission(p_property,'staff.manage') then raise exception 'not permitted' using errcode='42501'; end if;
 if p_provider not in ('agoda','booking_com','makemytrip') or p_provider is null then raise exception 'unknown provider' using errcode='22023'; end if;
 if p_external_property_id is null or p_external_property_id !~ '^[1-9][0-9]{0,19}$' then raise exception 'enter the numeric provider hotel ID' using errcode='22023'; end if;
 if p_credentials_ref is not null and p_credentials_ref !~ '^[a-zA-Z0-9_:-]{1,100}$' then raise exception 'enter a server credential reference, never a secret' using errcode='22023'; end if;
 select tenant_id into v_tenant from public.properties where id=p_property;
 insert into public.channel_connections(tenant_id,property_id,provider,credentials_ref,status,external_property_id)
 values(v_tenant,p_property,p_provider,p_credentials_ref,'paused',p_external_property_id)
 on conflict(property_id,provider) do update set external_property_id=excluded.external_property_id,credentials_ref=excluded.credentials_ref,status='paused',sandbox_approved=false
 returning id into v_id;
 return v_id;
end $$;

-- Existing generic connection API cannot bypass preparation / approval.
create or replace function public.connect_channel(p_property uuid,p_provider text,p_credentials_ref text default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_tenant uuid; v_id uuid;
begin
 if not private.has_permission(p_property,'staff.manage') then raise exception 'not permitted' using errcode='42501'; end if;
 if p_provider is distinct from 'mock' then raise exception 'real providers require channel preparation and sandbox approval' using errcode='22023'; end if;
 select tenant_id into v_tenant from public.properties where id=p_property;
 insert into public.channel_connections(tenant_id,property_id,provider,credentials_ref) values(v_tenant,p_property,p_provider,p_credentials_ref)
 on conflict(property_id,provider) do update set credentials_ref=excluded.credentials_ref,status='active' returning id into v_id;
 return v_id;
end $$;

create function public.approve_channel_sandbox(p_connection uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 update public.channel_connections c set sandbox_approved=true,status='active'
 where c.id=p_connection and c.provider in ('agoda','booking_com') and c.external_property_id is not null and c.credentials_ref is not null
 and private.tenant_is_active(c.tenant_id);
 if not found then raise exception 'connection is not ready for sandbox testing' using errcode='22023'; end if;
end $$;

create function public.claim_sync_jobs_v2(p_limit int default 10)
returns table(job_id uuid,connection_id uuid,provider text,credentials_ref text,type_id uuid,external_room_id text,date_from date,date_to date,attempt int,lease_token uuid,external_property_id text,environment text)
language sql security definer set search_path='' as $$
 with picked as (
 select j.id from public.sync_jobs j join public.channel_connections c on c.id=j.connection_id
 where c.status='active' and private.tenant_is_active(c.tenant_id) and (c.provider='mock' or c.sandbox_approved)
 and exists(select 1 from public.channel_unit_mappings m where m.connection_id=c.id and m.type_id=j.type_id)
 and ((j.status='queued' and j.next_attempt_at<=now()) or (j.status='running' and j.locked_at<now()-interval '5 minutes'))
 -- Never run a newer push concurrently with an in-flight push for the same room.
 and not exists(select 1 from public.sync_jobs r where r.connection_id=j.connection_id and r.type_id=j.type_id and r.id<>j.id and r.status='running')
 order by j.created_at limit greatest(1,least(p_limit,50)) for update of j skip locked
 ), upd as (
 update public.sync_jobs j set status='running',locked_at=now(),attempts=j.attempts+1,lease_token=gen_random_uuid()
 from picked where j.id=picked.id returning j.*
 ) select u.id,u.connection_id,c.provider,c.credentials_ref,u.type_id,m.external_room_id,u.date_from,u.date_to,u.attempts,u.lease_token,c.external_property_id,c.environment
 from upd u join public.channel_connections c on c.id=u.connection_id
 join public.channel_unit_mappings m on m.connection_id=u.connection_id and m.type_id=u.type_id
$$;
create function public.complete_sync_job_v2(p_id uuid,p_lease uuid,p_ok boolean,p_error text default null) returns boolean
language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.sync_jobs where id=p_id and status='running' and lease_token=p_lease for update;
 if not found then return false; end if;
 perform public.complete_sync_job(p_id,p_ok,left(p_error,500));
 return true;
end $$;

-- Preserve legacy mock clients, but prevent unfenced clients from touching real provider jobs.
alter function public.claim_sync_jobs(int) rename to claim_sync_jobs_legacy;
create function public.claim_sync_jobs(p_limit int default 10)
returns table(job_id uuid,connection_id uuid,provider text,credentials_ref text,type_id uuid,external_room_id text,date_from date,date_to date,attempt int)
language sql security definer set search_path='' as $$
 with picked as (
 select j.id from public.sync_jobs j join public.channel_connections c on c.id=j.connection_id
 where c.provider='mock' and c.status='active' and private.tenant_is_active(c.tenant_id)
 and ((j.status='queued' and j.next_attempt_at<=now()) or (j.status='running' and j.locked_at<now()-interval '5 minutes'))
 order by j.created_at limit greatest(1,least(p_limit,50)) for update of j skip locked
 ), upd as (
 update public.sync_jobs j set status='running',locked_at=now(),attempts=j.attempts+1 from picked where j.id=picked.id returning j.*
 ) select u.id,u.connection_id,c.provider,c.credentials_ref,u.type_id,m.external_room_id,u.date_from,u.date_to,u.attempts
 from upd u join public.channel_connections c on c.id=u.connection_id
 join public.channel_unit_mappings m on m.connection_id=u.connection_id and m.type_id=u.type_id
$$;
-- Worker uses v2 only. Remove old entry point, which could claim paused / unrelated jobs.
revoke all on function public.claim_sync_jobs_legacy(int) from public,anon,authenticated,service_role;
revoke all on function public.prepare_channel(uuid,text,text,text),public.approve_channel_sandbox(uuid),public.claim_sync_jobs_v2(int),public.complete_sync_job_v2(uuid,uuid,boolean,text),public.claim_sync_jobs(int) from public,anon,authenticated;
grant execute on function public.prepare_channel(uuid,text,text,text) to authenticated;
grant execute on function public.approve_channel_sandbox(uuid),public.claim_sync_jobs_v2(int),public.complete_sync_job_v2(uuid,uuid,boolean,text),public.claim_sync_jobs(int) to service_role;
