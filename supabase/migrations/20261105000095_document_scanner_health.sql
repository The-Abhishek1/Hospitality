create table private.document_scanner_health(
 singleton boolean primary key default true check(singleton),ready boolean not null default false,
 checked_at timestamptz not null default now(),last_ready_at timestamptz
);
revoke all on private.document_scanner_health from public,anon,authenticated,service_role;
create function public.document_scanner_heartbeat(p_ready boolean)returns void
language sql security definer set search_path=''as $$
 insert into private.document_scanner_health(singleton,ready,checked_at,last_ready_at)values(true,coalesce(p_ready,false),clock_timestamp(),case when p_ready then clock_timestamp()end)
 on conflict(singleton)do update set ready=excluded.ready,checked_at=excluded.checked_at,last_ready_at=coalesce(excluded.last_ready_at,document_scanner_health.last_ready_at)
$$;
revoke all on function public.document_scanner_heartbeat(boolean)from public,anon,authenticated;
grant execute on function public.document_scanner_heartbeat(boolean)to service_role;
alter function public.whatsapp_journey_workspace(uuid,uuid)rename to whatsapp_journey_workspace_before_scan_health;
revoke all on function public.whatsapp_journey_workspace_before_scan_health(uuid,uuid)from public,anon,authenticated,service_role;
create function public.whatsapp_journey_workspace(p_property uuid,p_reservation uuid default null)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare data jsonb;
begin
 data:=public.whatsapp_journey_workspace_before_scan_health(p_property,p_reservation);
 return data||jsonb_build_object('scanner',jsonb_build_object('ready',coalesce((select ready and checked_at>now()-interval '5 minutes'from private.document_scanner_health where singleton),false),'last_ready_at',(select last_ready_at from private.document_scanner_health where singleton),'pending',(select count(*)from public.guest_documents where property_id=p_property and status='uploaded')));
end $$;
revoke all on function public.whatsapp_journey_workspace(uuid,uuid)from public,anon;
grant execute on function public.whatsapp_journey_workspace(uuid,uuid)to authenticated;
