-- Staff-controlled exceptions, with sticky manual handling to prevent later duplicate imports.
create table public.channel_review_cases(
 id uuid primary key default gen_random_uuid(),connection_id uuid not null references public.channel_connections(id) on delete cascade,
 tenant_id uuid not null,property_id uuid not null,external_reservation_id text not null,
 latest_event_id uuid not null references public.channel_events(id) on delete cascade,revision timestamptz not null,
 status text not null default 'open' check(status in('open','resolved')),management_mode text not null default 'automatic' check(management_mode in('automatic','manual')),
 version int not null default 1,reservation_id uuid references public.reservations(id),
 updated_at timestamptz not null default now(),unique(connection_id,external_reservation_id),
 foreign key(property_id,tenant_id) references public.properties(id,tenant_id) on delete cascade
);
create unique index channel_review_one_reservation on public.channel_review_cases(reservation_id) where reservation_id is not null;
create table public.channel_review_actions(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,property_id uuid not null,
 case_id uuid not null references public.channel_review_cases(id) on delete cascade,
 actor_id uuid not null references public.profiles(id),request_id uuid not null,action text not null,
 reason text not null check(length(reason) between 5 and 1000),payload jsonb not null,result jsonb not null,
 created_at timestamptz not null default now(),unique(property_id,request_id),
 foreign key(property_id,tenant_id) references public.properties(id,tenant_id) on delete cascade
);
do $$declare n text;begin
 foreach n in array array['channel_review_cases','channel_review_actions']loop
 execute format('alter table public.%I enable row level security',n);
 execute format('create policy manager_read on public.%I for select to authenticated using(private.has_permission(property_id,''staff.manage''))',n);
 execute format('create policy platform_account_active on public.%I as restrictive for all to authenticated using(private.tenant_is_active(tenant_id))with check(private.tenant_is_active(tenant_id))',n);
 end loop;
end $$;

create function private.record_channel_review(p_event uuid)returns void
language plpgsql security definer set search_path=''as $$
declare e public.channel_events;rev timestamptz;
begin
 select * into e from public.channel_events where id=p_event;
 if e.payload->>'type' is distinct from 'agoda.snapshot' or e.status not in('failed','dead') then return;end if;
 begin rev:=(e.payload->>'revision')::timestamptz;exception when others then return;end;
 if rev is null or coalesce(e.payload->>'external_reservation_id','')!~'^[1-9][0-9]{0,19}$'then return;end if;
 insert into public.channel_review_cases(connection_id,tenant_id,property_id,external_reservation_id,latest_event_id,revision)
 values(e.connection_id,e.tenant_id,e.property_id,e.payload->>'external_reservation_id',e.id,rev)
 on conflict(connection_id,external_reservation_id)do update set
 latest_event_id=excluded.latest_event_id,revision=excluded.revision,status='open',version=public.channel_review_cases.version+1,updated_at=now()
 where excluded.revision>=public.channel_review_cases.revision and(public.channel_review_cases.latest_event_id<>excluded.latest_event_id or public.channel_review_cases.status<>'open');
end $$;
revoke all on function private.record_channel_review(uuid)from public,anon,authenticated;

alter function private.process_channel_event(uuid)rename to process_automatic_channel_event;
create function private.process_channel_event(p_event uuid)returns void
language plpgsql security definer set search_path=''as $$
declare e public.channel_events;c public.channel_review_cases;rev timestamptz;
begin
 select * into e from public.channel_events where id=p_event for update;
 if e.payload->>'type'='agoda.snapshot' then
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(e.connection_id::text||':'||(e.payload->>'external_reservation_id'),0));
 select * into c from public.channel_review_cases where connection_id=e.connection_id and external_reservation_id=e.payload->>'external_reservation_id' for update;
 if found and c.management_mode='manual' then
 begin rev:=(e.payload->>'revision')::timestamptz;exception when others then rev:=null;end;
 if rev is not null and(rev<c.revision or(rev=c.revision and c.status='resolved'and e.payload->>'status'=(select payload->>'status'from public.channel_events where id=c.latest_event_id)))then
 update public.channel_events set status='processed',processed_at=now(),error=null where id=e.id;return;
 end if;
 update public.channel_events set status='dead',error='This booking is managed manually. Review the latest provider change before updating the PMS.',attempts=greatest(attempts,1)where id=e.id;
 perform private.record_channel_review(e.id);return;
 end if;
 end if;
 perform private.process_automatic_channel_event(p_event);
 select * into e from public.channel_events where id=p_event;
 if e.status in('failed','dead')then perform private.record_channel_review(e.id);
 elsif e.status='processed'then
 update public.channel_review_cases set status='resolved',latest_event_id=e.id,revision=(e.payload->>'revision')::timestamptz,reservation_id=(select bs.reservation_id from public.channel_booking_state bs where bs.connection_id=e.connection_id and bs.external_reservation_id=e.payload->>'external_reservation_id'),version=version+1,updated_at=now()
 where connection_id=e.connection_id and external_reservation_id=e.payload->>'external_reservation_id' and revision<=(e.payload->>'revision')::timestamptz and status='open'and management_mode='automatic';
 end if;
end $$;
revoke all on function private.process_channel_event(uuid)from public,anon,authenticated;
-- Backfill existing failed snapshots; chronological ordering leaves the newest at the top of each case.
do $$declare e record;begin
 for e in select id from public.channel_events where status in('failed','dead')and payload->>'type'='agoda.snapshot'order by received_at,id loop
 perform private.record_channel_review(e.id);
 end loop;
end $$;

create function public.channel_review_command(p_property uuid,p_case uuid,p_version int,p_request uuid,p_action text,p_details jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$
declare c public.channel_review_cases;e public.channel_events;conn public.channel_connections;prior public.channel_review_actions;
 r public.reservations;reason text;result jsonb;linked_type uuid;existing_state uuid;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'not permitted'using errcode='42501';end if;
 if p_request is null or jsonb_typeof(p_details)is distinct from 'object'then raise exception 'Reload the review form.'using errcode='22023';end if;
 reason:=trim(p_details->>'reason');
 if reason is null or length(reason)not between 5 and 1000 or p_action is null or p_action not in('retry','link','resolve_manual')then raise exception 'Choose an action and enter a reason (5–1000 characters).'using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('channel-review-command:'||p_property::text||p_request::text,0));
 select * into prior from public.channel_review_actions where property_id=p_property and request_id=p_request;
 if found then
 if prior.actor_id<>auth.uid()or prior.case_id<>p_case or prior.action<>p_action or prior.payload<>p_details then raise exception 'This request was already used for another review action.'using errcode='22023';end if;
 return prior.result;
 end if;
 select * into c from public.channel_review_cases where id=p_case and property_id=p_property;
 if not found then raise exception 'Review case not found.'using errcode='P0002';end if;
 -- Same lock order as the worker: event -> booking advisory -> case -> reservation.
 select * into e from public.channel_events where id=c.latest_event_id for update;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.connection_id::text||':'||c.external_reservation_id,0));
 select * into c from public.channel_review_cases where id=p_case for update;
 if c.version is distinct from p_version or c.latest_event_id<>e.id or c.status<>'open'then raise exception 'This case changed. Refresh before taking action.'using errcode='40001';end if;
 select * into conn from public.channel_connections where id=c.connection_id;
 if e.payload->>'external_property_id' is distinct from conn.external_property_id then raise exception 'Provider hotel mapping changed; contact your platform operator.'using errcode='22023';end if;
 if exists(select 1 from public.channel_events newer where newer.connection_id=c.connection_id and newer.payload->>'external_reservation_id'=c.external_reservation_id and newer.payload->>'type'='agoda.snapshot'and(newer.payload->>'revision')::timestamptz>c.revision)then raise exception 'A newer provider revision is waiting. Refresh after processing it.'using errcode='40001';end if;
 if p_action='retry'then
 if c.management_mode='manual'then raise exception 'This booking is managed manually; process its changes manually to avoid duplicate reservations.'using errcode='22023';end if;
 if conn.status<>'active'or not conn.sandbox_approved then raise exception 'The sandbox connection must be active before retrying.'using errcode='22023';end if;
 update public.channel_events set status='received',attempts=0,next_attempt_at=now(),error=null where id=e.id;
 update public.channel_review_cases set version=version+1,updated_at=now()where id=c.id;
 result:=jsonb_build_object('message','Import queued for retry. The case stays open until processing succeeds.');
 else
 if p_details->>'confirmed' is distinct from 'true'then raise exception 'Confirm you checked the provider and recorded the required inventory and financial actions.'using errcode='22023';end if;
 if p_action='link'then
 if not private.has_permission(p_property,'reservations.write')then raise exception 'Reservation management access is required.'using errcode='42501';end if;
 if e.payload->>'review_reason'is not null or e.payload->>'payment_model'is distinct from 'property_collect'or e.payload->>'room_count'is distinct from '1'or e.payload->>'status'not in('ConfirmBooking','AmendBooking')then raise exception 'Only a complete, single-room Property Collect snapshot can be linked. Resolve other cases manually.'using errcode='22023';end if;
 select * into r from public.reservations where id=(p_details->>'reservation_id')::uuid and property_id=p_property for update;
 if not found or r.status not in('confirmed','checked_in')or r.check_in is distinct from(e.payload->>'check_in')::date or r.check_out is distinct from(e.payload->>'check_out')::date or r.adults is distinct from(e.payload->>'adults')::int or r.children is distinct from(e.payload->>'children')::int or r.currency::text is distinct from e.payload->>'currency' or r.total_amount is distinct from(e.payload->>'total_amount')::numeric then raise exception 'Choose a reservation with matching dates, occupancy, currency and total.'using errcode='22023';end if;
 select m.type_id into linked_type from public.channel_unit_mappings m where m.connection_id=conn.id and m.external_room_id=e.payload->>'external_room_id';
 if linked_type is null or not exists(select 1 from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.reservation_id=r.id and h.active and u.type_id=linked_type and h.during=daterange(r.check_in,r.check_out,'[)'))then raise exception 'The reservation must hold a matching mapped room for the entire stay.'using errcode='22023';end if;
 select bs.reservation_id into existing_state from public.channel_booking_state bs where bs.connection_id=conn.id and bs.external_reservation_id=c.external_reservation_id;
 if(existing_state is not null and existing_state<>r.id)or exists(select 1 from public.channel_booking_state where reservation_id=r.id and(connection_id<>conn.id or external_reservation_id<>c.external_reservation_id))or exists(select 1 from public.channel_review_cases where reservation_id=r.id and id<>c.id)or(r.channel_ref is not null and(r.channel_ref<>'agoda:'||c.external_reservation_id or r.source<>'ota'))then raise exception 'This booking or reservation is already linked elsewhere.'using errcode='22023';end if;
 update public.reservations set source='ota',channel_ref='agoda:'||c.external_reservation_id where id=r.id;
 insert into public.reservation_events(tenant_id,property_id,reservation_id,event_type,actor_id,details)values(c.tenant_id,p_property,r.id,'channel_linked_manually',auth.uid(),jsonb_build_object('provider','agoda','booking_id',c.external_reservation_id,'reason',reason,'previous_source',r.source,'previous_channel_ref',r.channel_ref));
 update public.channel_review_cases set reservation_id=r.id where id=c.id;
 end if;
 update public.channel_events set status='processed',processed_at=now(),error=null where id=e.id;
 update public.channel_review_cases set status='resolved',management_mode='manual',version=version+1,updated_at=now()where id=c.id;
 result:=jsonb_build_object('message',case when p_action='link'then'Reservation linked. Future provider changes will require manual review.'else'Manual resolution recorded. Future provider changes will reopen this case.'end);
 end if;
 insert into public.channel_review_actions(tenant_id,property_id,case_id,actor_id,request_id,action,reason,payload,result)values(c.tenant_id,p_property,c.id,auth.uid(),p_request,p_action,reason,p_details,result);
 return result;
end $$;
revoke all on function public.channel_review_command(uuid,uuid,int,uuid,text,jsonb)from public,anon;
grant execute on function public.channel_review_command(uuid,uuid,int,uuid,text,jsonb)to authenticated;
