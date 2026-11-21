-- Agoda sandbox discovery, durable polling and explicit nightly rate publication.
-- Reservations that cannot be represented safely remain in the existing review queue.
create table public.channel_products (
 connection_id uuid primary key references public.channel_connections(id) on delete cascade,
 tenant_id uuid not null, property_id uuid not null, snapshot jsonb not null, fetched_at timestamptz not null default now()
);
create table public.channel_poll_state (
 connection_id uuid primary key references public.channel_connections(id) on delete cascade,
 tenant_id uuid not null, property_id uuid not null,
 cursor_at timestamptz not null default now()-interval '24 hours',
 next_poll_at timestamptz not null default now(), lease_token uuid, locked_until timestamptz,
 attempts int not null default 0, last_error text, last_success_at timestamptz
);
create table public.channel_rate_calendar (
 connection_id uuid not null references public.channel_connections(id) on delete cascade,
 tenant_id uuid not null,property_id uuid not null,type_id uuid not null,rate_plan_id uuid not null,
 day date not null,amount numeric(12,2) not null check(amount>0),currency text not null check(currency~'^[A-Z]{3}$'),
 closed boolean,cta boolean,ctd boolean,min_los int check(min_los between 1 and 99),max_los int check(max_los between 0 and 99),
 updated_at timestamptz not null default now(),primary key(connection_id,type_id,rate_plan_id,day),
 foreign key(type_id,property_id) references public.accommodation_types(id,property_id),
 foreign key(rate_plan_id,property_id) references public.rate_plans(id,property_id),
 check(max_los=0 or max_los>=min_los)
);
create table public.channel_booking_state (
 connection_id uuid not null references public.channel_connections(id) on delete cascade,
 tenant_id uuid not null,property_id uuid not null,external_reservation_id text not null,
 revision timestamptz not null,provider_status text not null,reservation_id uuid references public.reservations(id),
 primary key(connection_id,external_reservation_id)
);
do $$ declare n text; begin
 foreach n in array array['channel_products','channel_poll_state','channel_rate_calendar','channel_booking_state'] loop
 execute format('alter table public.%I enable row level security',n);
 execute format('create policy manager_read on public.%I for select to authenticated using(private.has_permission(property_id,''staff.manage''))',n);
 execute format('create policy platform_account_active on public.%I as restrictive for all to authenticated using(private.tenant_is_active(tenant_id)) with check(private.tenant_is_active(tenant_id))',n);
 end loop;
end $$;

create function public.save_channel_products(p_connection uuid,p_snapshot jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare c public.channel_connections;
begin
 select * into c from public.channel_connections where id=p_connection and provider='agoda' and status='active' and sandbox_approved for share;
 if not found or not private.tenant_is_active(c.tenant_id) then raise exception 'inactive Agoda sandbox connection';end if;
 if p_snapshot->>'hotelId' is distinct from c.external_property_id or jsonb_typeof(p_snapshot->'rooms') is distinct from 'array' or jsonb_typeof(p_snapshot->'rates') is distinct from 'array' or jsonb_typeof(p_snapshot->'products') is distinct from 'array' then raise exception 'invalid product snapshot';end if;
 insert into public.channel_products(connection_id,tenant_id,property_id,snapshot) values(c.id,c.tenant_id,c.property_id,p_snapshot)
 on conflict(connection_id) do update set snapshot=excluded.snapshot,fetched_at=now();
end $$;

create function public.claim_channel_poll() returns jsonb
language plpgsql security definer set search_path='' as $$
declare c public.channel_connections; s public.channel_poll_state; until_at timestamptz;
begin
 insert into public.channel_poll_state(connection_id,tenant_id,property_id)
 select id,tenant_id,property_id from public.channel_connections where provider='agoda' and status='active' and sandbox_approved
 on conflict do nothing;
 select ps.* into s from public.channel_poll_state ps join public.channel_connections cc on cc.id=ps.connection_id
 where cc.provider='agoda' and cc.status='active' and cc.sandbox_approved and private.tenant_is_active(cc.tenant_id)
 and ps.next_poll_at<=now() and (ps.locked_until is null or ps.locked_until<now()) and ps.cursor_at<now()-interval '30 seconds'
 order by ps.next_poll_at limit 1 for update of ps skip locked;
 if not found then return null;end if;
 select * into c from public.channel_connections where id=s.connection_id;
 until_at:=least(s.cursor_at+interval '55 minutes',now()-interval '30 seconds');
 update public.channel_poll_state set lease_token=gen_random_uuid(),locked_until=now()+interval '10 minutes' where connection_id=c.id returning * into s;
 return jsonb_build_object('connectionId',c.id,'credentialsRef',c.credentials_ref,'externalPropertyId',c.external_property_id,'environment',c.environment,'lease',s.lease_token,'from',s.cursor_at-interval '5 seconds','to',until_at);
end $$;

create function public.complete_channel_poll(p_connection uuid,p_lease uuid,p_to timestamptz,p_ok boolean,p_error text default null) returns boolean
language plpgsql security definer set search_path='' as $$
declare s public.channel_poll_state;
begin
 select * into s from public.channel_poll_state where connection_id=p_connection and lease_token=p_lease and locked_until>now() for update;
 if not found then return false;end if;
 if p_ok then
 if p_to<=s.cursor_at or p_to>s.cursor_at+interval '55 minutes' or p_to>now() then raise exception 'invalid polling checkpoint';end if;
 update public.channel_poll_state set cursor_at=p_to,next_poll_at=case when p_to<now()-interval '5 minutes' then now() else now()+interval '5 minutes' end,
 locked_until=null,lease_token=null,attempts=0,last_error=null,last_success_at=now() where connection_id=p_connection;
 else
 update public.channel_poll_state set locked_until=null,lease_token=null,attempts=attempts+1,last_error=left(p_error,500),next_poll_at=now()+make_interval(secs=>least(3600,30*power(2,least(s.attempts,7))::int)) where connection_id=p_connection;
 end if;
 return true;
end $$;

create function public.map_channel_rate(p_connection uuid,p_rate uuid,p_external text) returns void
language plpgsql security definer set search_path='' as $$
declare c public.channel_connections;
begin
 select * into c from public.channel_connections where id=p_connection;
 if not found or not private.has_permission(c.property_id,'staff.manage') then raise exception 'not permitted' using errcode='42501';end if;
 if c.provider<>'agoda' or p_external is null or p_external!~'^[1-9][0-9]{0,19}$' or not exists(select 1 from public.rate_plans where id=p_rate and property_id=c.property_id) then raise exception 'invalid Agoda rate mapping' using errcode='22023';end if;
 if not exists(select 1 from public.channel_products cp,jsonb_array_elements(cp.snapshot->'rates') r where cp.connection_id=c.id and r->>'id'=p_external and r->>'master'='0') then raise exception 'Refresh Agoda products and choose a standalone master rate.' using errcode='22023';end if;
 if exists(select 1 from public.channel_rate_calendar where connection_id=c.id and rate_plan_id=p_rate) then raise exception 'Existing calendar prices must be reviewed before remapping this rate.' using errcode='22023';end if;
 insert into public.channel_rate_mappings(connection_id,tenant_id,property_id,rate_plan_id,external_rate_id) values(c.id,c.tenant_id,c.property_id,p_rate,p_external)
 on conflict(connection_id,rate_plan_id) do update set external_rate_id=excluded.external_rate_id;
end $$;

create function public.set_channel_rates(p_connection uuid,p_type uuid,p_rate uuid,p_from date,p_to date,p_amount numeric,p_closed boolean default null,p_cta boolean default null,p_ctd boolean default null,p_min_los int default null,p_max_los int default null) returns int
language plpgsql security definer set search_path='' as $$
declare c public.channel_connections;p public.properties;room_id text;rate_id text;snapshot jsonb;num int;
begin
 select * into c from public.channel_connections where id=p_connection;
 if not found or not private.has_permission(c.property_id,'staff.manage') then raise exception 'not permitted' using errcode='42501';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('channel-rate:'||c.id::text,0));
 select * into p from public.properties where id=c.property_id for share;
 if c.provider<>'agoda' or p_from is null or p_to is null or p_from<(now() at time zone p.timezone)::date or p_to<=p_from or p_to-p_from>366 or p_to>(now() at time zone p.timezone)::date+730
 or p_amount is null or p_amount<=0 or p_amount>999999999 or p_amount<>round(p_amount,2)
 or (p_min_los is not null and p_min_los not between 1 and 99) or (p_max_los is not null and p_max_los not between 0 and 99) or (p_max_los>0 and p_min_los>p_max_los)
 then raise exception 'Check the date range, amount and stay restrictions.' using errcode='22023';end if;
 select m.external_room_id into room_id from public.channel_unit_mappings m where m.connection_id=c.id and m.type_id=p_type;
 select m.external_rate_id into rate_id from public.channel_rate_mappings m where m.connection_id=c.id and m.rate_plan_id=p_rate;
 select cp.snapshot into snapshot from public.channel_products cp where cp.connection_id=c.id and cp.fetched_at>now()-interval '24 hours';
 if snapshot->>'currency' is distinct from p.currency::text or room_id is null or rate_id is null or not exists(select 1 from jsonb_array_elements(snapshot->'products') x where x->>'roomId'=room_id and x->>'rateId'=rate_id)
 then raise exception 'Refresh Agoda products and verify currency and room/rate mappings.' using errcode='22023';end if;
 if not exists(select 1 from jsonb_array_elements(snapshot->'rooms') x where x->>'id'=room_id and p_amount between (x->>'minRate')::numeric and (x->>'maxRate')::numeric) then raise exception 'Price outside provider room limits.' using errcode='22023';end if;
 insert into public.channel_rate_calendar(connection_id,tenant_id,property_id,type_id,rate_plan_id,day,amount,currency,closed,cta,ctd,min_los,max_los)
 select c.id,c.tenant_id,c.property_id,p_type,p_rate,d::date,p_amount,p.currency,p_closed,p_cta,p_ctd,p_min_los,p_max_los from generate_series(p_from,p_to-1,interval '1 day')d
 on conflict(connection_id,type_id,rate_plan_id,day) do update set amount=excluded.amount,closed=excluded.closed,cta=excluded.cta,ctd=excluded.ctd,min_los=excluded.min_los,max_los=excluded.max_los,updated_at=now();
 get diagnostics num=row_count;
 perform private.enqueue_sync(c.id,p_type,p_from,p_to);
 return num;
end $$;

create function public.channel_rates_range(p_connection uuid,p_type uuid,p_from date,p_to date) returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(x.push),'[]'::jsonb) from (
 select jsonb_build_object('externalRoomId',m.external_room_id,'externalRateId',r.external_rate_id,'currency',cal.currency,'days',jsonb_agg(jsonb_build_object('day',cal.day,'amount',cal.amount::text,'closed',cal.closed,'cta',cal.cta,'ctd',cal.ctd,'minLos',cal.min_los,'maxLos',cal.max_los)order by cal.day)) push
 from public.channel_rate_calendar cal join public.channel_unit_mappings m on m.connection_id=cal.connection_id and m.type_id=cal.type_id
 join public.channel_rate_mappings r on r.connection_id=cal.connection_id and r.rate_plan_id=cal.rate_plan_id
 where cal.connection_id=p_connection and cal.type_id=p_type and cal.day>=p_from and cal.day<p_to
 group by m.external_room_id,r.external_rate_id,cal.currency)x
$$;

-- Preserve the mock importer while adding a revision-aware snapshot importer for Agoda.
alter function private.process_channel_event(uuid) rename to process_mock_channel_event;
create function private.process_channel_event(p_event uuid) returns void
language plpgsql security definer set search_path='' as $$
declare e public.channel_events;c public.channel_connections;pl jsonb;p public.properties;s public.channel_booking_state;r public.reservations;
 revision_at timestamptz;booking_id text;type_id uuid;capacity int;guest_id uuid;unit_id uuid;imported_id uuid;
begin
 select * into e from public.channel_events where id=p_event for update;
 select * into c from public.channel_connections where id=e.connection_id;
 if c.provider='mock' then perform private.process_mock_channel_event(p_event);return;end if;
 begin
 if c.provider<>'agoda' or c.status<>'active' or not c.sandbox_approved or not private.tenant_is_active(c.tenant_id) then raise exception 'Inactive or unsupported provider connection';end if;
 pl:=e.payload;
 if pl->>'type' is distinct from 'agoda.snapshot' or pl->>'external_property_id' is distinct from c.external_property_id then raise exception 'Invalid Agoda property snapshot';end if;
 booking_id:=pl->>'external_reservation_id';revision_at:=(pl->>'revision')::timestamptz;
 if booking_id is null or booking_id!~'^[1-9][0-9]{0,19}$' or revision_at is null or pl->>'status' not in ('ConfirmBooking','AmendBooking','CancelBooking') then raise exception 'Invalid Agoda reservation revision';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.id::text||':'||booking_id,0));
 select * into s from public.channel_booking_state where connection_id=c.id and external_reservation_id=booking_id for update;
 if found and (s.revision>revision_at or (s.revision=revision_at and s.provider_status=pl->>'status')) then
 update public.channel_events set status='processed',processed_at=now(),error=null where id=e.id;return;
 elsif found and s.revision=revision_at then raise exception 'Conflicting Agoda statuses at same revision require review';end if;
 if exists(select 1 from public.channel_events newer where newer.connection_id=c.id and newer.id<>e.id
 and newer.payload->>'external_reservation_id'=booking_id and newer.payload->>'type'='agoda.snapshot'
 and (newer.payload->>'revision')::timestamptz>revision_at) then
 update public.channel_events set status='processed',processed_at=now(),error=null where id=e.id;return;
 end if;
 if pl->>'review_reason' is not null then raise exception '%',pl->>'review_reason';end if;
 select * into p from public.properties where id=c.property_id for share;
 if pl->>'currency' is distinct from p.currency::text then raise exception 'Agoda currency differs from property currency';end if;
 if pl->>'status'='CancelBooking' then
 if s.reservation_id is not null then
 select * into r from public.reservations where id=s.reservation_id for update;
 if r.status not in ('confirmed','cancelled') then raise exception 'Cancellation of an in-house or completed stay needs review';end if;
 if exists(select 1 from public.folios f where f.reservation_id=r.id) then raise exception 'Reservation has billing activity; review cancellation and penalties';end if;
 update public.reservations set status='cancelled',cancelled_at=coalesce(cancelled_at,now()) where id=r.id;
 update public.unit_holds set active=false where reservation_id=r.id and active;
 insert into public.reservation_events(tenant_id,property_id,reservation_id,event_type,details) values(c.tenant_id,c.property_id,r.id,'cancelled_by_channel',jsonb_build_object('provider','agoda','revision',revision_at));
 end if;
 else
 -- Do not misrepresent OTA-collected money as an amount the guest owes.
 if pl->>'payment_model' is distinct from 'property_collect' then raise exception 'Agoda Collect settlement requires review before importing guest billing';end if;
 if coalesce((pl->>'room_count')::int,0)<>1 then raise exception 'Multi-room booking requires group allocation and billing review';end if;
 if s.provider_status='CancelBooking' then raise exception 'Restoring a cancelled Agoda booking requires staff review';end if;
 select m.type_id,t.max_occupancy into type_id,capacity from public.channel_unit_mappings m join public.accommodation_types t on t.id=m.type_id where m.connection_id=c.id and m.external_room_id=pl->>'external_room_id';
 if type_id is null then raise exception 'Unmapped or inactive Agoda room';end if;
 if (pl->>'check_out')::date<=(pl->>'check_in')::date or (pl->>'adults')::int<1 or (pl->>'children')::int<0 or (pl->>'adults')::int+(pl->>'children')::int>capacity or (pl->>'total_amount')::numeric<0 then raise exception 'Invalid Agoda dates, occupancy or amount';end if;
 if s.reservation_id is null then
 insert into public.guests(tenant_id,full_name,phone,email) values(c.tenant_id,coalesce(nullif(pl->>'guest_name',''),'Agoda guest'),pl->>'guest_phone',pl->>'guest_email') returning id into guest_id;
 imported_id:=private.create_reservation_core(c.property_id,guest_id,type_id,(pl->>'check_in')::date,(pl->>'check_out')::date,(pl->>'adults')::int,(pl->>'children')::int,null,'ota','agoda:'||booking_id,null,(pl->>'total_amount')::numeric);
 else
 select * into r from public.reservations where id=s.reservation_id for update;
 if r.status<>'confirmed' then raise exception 'Only confirmed stays can be modified automatically';end if;
 if exists(select 1 from public.folios f where f.reservation_id=r.id) then raise exception 'Reservation has billing activity; review amendment';end if;
 update public.unit_holds set active=false where reservation_id=r.id and active;
 unit_id:=private.allocate_unit(c.property_id,c.tenant_id,type_id,(pl->>'check_in')::date,(pl->>'check_out')::date,r.id);
 if unit_id is null then raise exception 'No availability for Agoda amendment';end if;
 update public.reservations set check_in=(pl->>'check_in')::date,check_out=(pl->>'check_out')::date,adults=(pl->>'adults')::int,children=(pl->>'children')::int,total_amount=(pl->>'total_amount')::numeric where id=r.id;
 insert into public.reservation_events(tenant_id,property_id,reservation_id,event_type,details) values(c.tenant_id,c.property_id,r.id,'modified_by_channel',jsonb_build_object('provider','agoda','revision',revision_at));
 imported_id:=r.id;
 end if;
 end if;
 insert into public.channel_booking_state(connection_id,tenant_id,property_id,external_reservation_id,revision,provider_status,reservation_id)
 values(c.id,c.tenant_id,c.property_id,booking_id,revision_at,pl->>'status',coalesce(imported_id,s.reservation_id))
 on conflict(connection_id,external_reservation_id) do update set revision=excluded.revision,provider_status=excluded.provider_status,reservation_id=excluded.reservation_id;
 update public.channel_events set status='processed',processed_at=now(),error=null where id=e.id;
 exception when others then
 update public.channel_events set status=case when attempts+1>=5 then 'dead' else 'failed' end,error=left(sqlerrm,500),attempts=attempts+1,next_attempt_at=now()+make_interval(mins=>power(2,least(attempts+1,10))::int) where id=e.id;
 end;
end $$;
revoke all on function private.process_channel_event(uuid) from public,anon,authenticated;
revoke all on function public.save_channel_products(uuid,jsonb),public.claim_channel_poll(),public.complete_channel_poll(uuid,uuid,timestamptz,boolean,text),public.channel_rates_range(uuid,uuid,date,date),public.map_channel_rate(uuid,uuid,text),public.set_channel_rates(uuid,uuid,uuid,date,date,numeric,boolean,boolean,boolean,int,int) from public,anon,authenticated;
grant execute on function public.save_channel_products(uuid,jsonb),public.claim_channel_poll(),public.complete_channel_poll(uuid,uuid,timestamptz,boolean,text),public.channel_rates_range(uuid,uuid,date,date) to service_role;
grant execute on function public.map_channel_rate(uuid,uuid,text),public.set_channel_rates(uuid,uuid,uuid,date,date,numeric,boolean,boolean,boolean,int,int) to authenticated;
