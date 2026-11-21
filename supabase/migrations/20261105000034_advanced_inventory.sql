alter table public.accommodation_types add column description text not null default ''check(length(description)<=2000),add column version integer not null default 1;
alter table public.accommodation_units add column floor text not null default ''check(length(floor)<=50),add column notes text not null default ''check(length(notes)<=1000),add column version integer not null default 1;
alter table public.rate_plans add column description text not null default ''check(length(description)<=500),add column version integer not null default 1;
alter table public.unit_holds add column version integer not null default 1;
create table public.inventory_events(id uuid primary key default gen_random_uuid(),tenant_id uuid not null,property_id uuid not null,entity text not null,entity_id uuid not null,action text not null,actor_id uuid,details jsonb not null default '{}',created_at timestamptz not null default now(),foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade);
create index on public.inventory_events(property_id,entity_id,created_at);
alter table public.inventory_events enable row level security;
create policy inventory_events_read on public.inventory_events for select to authenticated using(private.has_permission(property_id,'inventory.manage'));
create table public.inventory_commands(id uuid primary key default gen_random_uuid(),tenant_id uuid not null,property_id uuid not null,request_id uuid not null,action text not null,entity_id uuid,payload jsonb not null,result_id uuid not null,created_at timestamptz not null default now(),unique(property_id,request_id),foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade);
alter table public.inventory_commands enable row level security;
create policy inventory_commands_read on public.inventory_commands for select to authenticated using(private.has_permission(property_id,'inventory.manage'));
create function private.inventory_version()returns trigger language plpgsql set search_path='' as $$begin new.version:=old.version+1;return new;end $$;
revoke all on function private.inventory_version()from public,anon,authenticated;
create trigger inventory_version before update on public.accommodation_types for each row execute function private.inventory_version();
create trigger inventory_version before update on public.accommodation_units for each row execute function private.inventory_version();
create trigger inventory_version before update on public.rate_plans for each row execute function private.inventory_version();
create trigger inventory_version before update on public.unit_holds for each row execute function private.inventory_version();

-- A hold obtains the room lock before insertion, serializing booking/block creation with room configuration.
create function private.inventory_hold_guard()returns trigger language plpgsql security definer set search_path='' as $$
declare u public.accommodation_units;capacity integer;guests integer;
begin
 if new.active then
 select * into u from public.accommodation_units where id=new.unit_id and property_id=new.property_id for update;
 if not found or not u.active then raise exception 'This room is inactive. Choose an active room.'using errcode='22023';end if;
 if new.kind='reservation'then select max_occupancy into capacity from public.accommodation_types where id=u.type_id for share;select adults+children into guests from public.reservations where id=new.reservation_id;if guests>capacity then raise exception 'Guest count exceeds the room type capacity.'using errcode='22023';end if;end if;
 end if;return new;
end $$;
revoke all on function private.inventory_hold_guard()from public,anon,authenticated;
create trigger inventory_hold_guard before insert or update of unit_id,during,active on public.unit_holds for each row execute function private.inventory_hold_guard();

create function private.inventory_config_guard()returns trigger language plpgsql security definer set search_path='' as $$
declare day date;
begin
 select(now()at time zone timezone)::date into day from public.properties where id=new.property_id;
 if tg_table_name='accommodation_units'then
 if(new.type_id is distinct from old.type_id)or(old.active and not new.active)then
 if exists(select 1 from public.unit_holds h left join public.reservations r on r.id=h.reservation_id where h.unit_id=old.id and h.active and(upper_inf(h.during)or upper(h.during)>day or r.status='checked_in'))then raise exception 'Move or resolve upcoming reservations and blocks before changing this room’s type or deactivating it.'using errcode='22023';end if;
 if exists(select 1 from public.tasks where unit_id=old.id and status in('open','in_progress'))then raise exception 'Resolve this room’s open tasks before changing its type or deactivating it.'using errcode='22023';end if;
 end if;
 elsif tg_table_name='accommodation_types'and new.max_occupancy<old.max_occupancy then
 if exists(select 1 from public.accommodation_units u join public.unit_holds h on h.unit_id=u.id join public.reservations r on r.id=h.reservation_id where u.type_id=old.id and h.active and(r.status='checked_in'or(r.status='confirmed'and r.check_out>day))and r.adults+r.children>new.max_occupancy)then raise exception 'Upcoming or in-house guests exceed this capacity. Resolve those bookings before reducing it.'using errcode='22023';end if;
 end if;return new;
end $$;
revoke all on function private.inventory_config_guard()from public,anon,authenticated;
create trigger inventory_config_guard before update on public.accommodation_units for each row execute function private.inventory_config_guard();
create trigger inventory_config_guard before update on public.accommodation_types for each row execute function private.inventory_config_guard();

create function private.inventory_audit()returns trigger language plpgsql security definer set search_path='' as $$
declare entity_kind text;before_data jsonb;after_data jsonb;
begin
 entity_kind:=case tg_table_name when 'accommodation_types'then 'types'when 'accommodation_units'then 'rooms'when 'rate_plans'then 'rates'else 'blocks'end;
 if tg_table_name='unit_holds'then if new.kind<>'block'then return new;end if;end if;
 after_data:=to_jsonb(new)-'tenant_id'-'property_id'-'version';
 if tg_op='UPDATE'then before_data:=to_jsonb(old)-'tenant_id'-'property_id'-'version';if tg_table_name='accommodation_units'and(before_data-'housekeeping_status')=(after_data-'housekeeping_status')then return new;end if;end if;
 insert into public.inventory_events(tenant_id,property_id,entity,entity_id,action,actor_id,details)values(new.tenant_id,new.property_id,entity_kind,new.id,case when tg_op='INSERT'then 'created'else 'updated'end,auth.uid(),jsonb_build_object('before',before_data,'after',after_data));return new;
end $$;
revoke all on function private.inventory_audit()from public,anon,authenticated;
create trigger inventory_audit after insert or update on public.accommodation_types for each row execute function private.inventory_audit();
create trigger inventory_audit after insert or update on public.accommodation_units for each row execute function private.inventory_audit();
create trigger inventory_audit after insert or update on public.rate_plans for each row execute function private.inventory_audit();
create trigger inventory_audit after insert or update on public.unit_holds for each row execute function private.inventory_audit();

create function public.inventory_save(p_property uuid,p_request uuid,p_section text,p_id uuid,p_version integer,p_details jsonb)returns uuid language plpgsql security definer set search_path='' as $$
declare tenant uuid;cmd public.inventory_commands;result_id uuid;old_version integer;room public.accommodation_units;hold public.unit_holds;amount numeric;capacity integer;target_type uuid;start_day date;end_day date;day date;active_value boolean;
begin
 if not private.has_permission(p_property,'inventory.manage')then raise exception 'not permitted'using errcode='42501';end if;
 if p_request is null or p_details is null or jsonb_typeof(p_details)<>'object'or p_section not in('types','rooms','rates','blocks','release')then raise exception 'Reload this inventory form.'using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('inventory-command:'||p_property::text||p_request::text,0));
 select * into cmd from public.inventory_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.action<>p_section or cmd.entity_id is distinct from p_id or cmd.payload is distinct from p_details then raise exception 'Request ID already used for different details.'using errcode='22023';end if;return cmd.result_id;end if;
 select tenant_id,(now()at time zone timezone)::date into tenant,day from public.properties where id=p_property;
 if p_section in('types','rooms','rates')then
 if length(trim(coalesce(p_details->>'name','')))not between 1 and 120 then raise exception 'Enter a name of 1–120 characters.'using errcode='22023';end if;
 if p_id is not null then
 if p_section='types'then select version into old_version from public.accommodation_types where id=p_id and property_id=p_property for update;
 elsif p_section='rooms'then select version into old_version from public.accommodation_units where id=p_id and property_id=p_property for update;
 else select version into old_version from public.rate_plans where id=p_id and property_id=p_property for update;end if;
 if old_version is null then raise exception 'Inventory item not found in this hotel.'using errcode='22023';end if;if old_version is distinct from p_version then raise exception 'This item changed. Refresh and review its latest settings.'using errcode='40001';end if;end if;
 if p_section='types'then
 capacity:=(p_details->>'capacity')::integer;if capacity is null or capacity not between 1 and 100 then raise exception 'Choose a capacity of 1–100 guests.'using errcode='22023';end if;
 if coalesce(p_details->>'base_rate','')!~'^[0-9]{1,10}(\.[0-9]{1,2})?$'then raise exception 'Enter a non-negative nightly rate with up to two decimals.'using errcode='22023';end if;amount:=(p_details->>'base_rate')::numeric;
 if coalesce(p_details->>'kind','')not in('room','suite','bed','entire_property')or length(coalesce(p_details->>'description',''))>2000 then raise exception 'Check the room type and description.'using errcode='22023';end if;
 if p_id is null then insert into public.accommodation_types(tenant_id,property_id,name,kind,max_occupancy,base_rate,description)values(tenant,p_property,trim(p_details->>'name'),p_details->>'kind',capacity,amount,coalesce(p_details->>'description',''))returning id into result_id;
 else update public.accommodation_types set name=trim(p_details->>'name'),kind=p_details->>'kind',max_occupancy=capacity,base_rate=amount,description=coalesce(p_details->>'description','')where id=p_id returning id into result_id;end if;
 elsif p_section='rooms'then
 target_type:=(p_details->>'type_id')::uuid;if not exists(select 1 from public.accommodation_types where id=target_type and property_id=p_property)then raise exception 'Choose a room type in this hotel.'using errcode='22023';end if;
 if length(coalesce(p_details->>'floor',''))>50 or length(coalesce(p_details->>'notes',''))>1000 then raise exception 'Keep floor under 50 characters and room notes under 1000.'using errcode='22023';end if;
 active_value:=coalesce((p_details->>'active')::boolean,true);
 if p_id is null then insert into public.accommodation_units(tenant_id,property_id,type_id,name,floor,notes,active,housekeeping_status)values(tenant,p_property,target_type,trim(p_details->>'name'),coalesce(p_details->>'floor',''),coalesce(p_details->>'notes',''),active_value,'dirty')returning id into result_id;
 else update public.accommodation_units set type_id=target_type,name=trim(p_details->>'name'),floor=coalesce(p_details->>'floor',''),notes=coalesce(p_details->>'notes',''),active=active_value where id=p_id returning id into result_id;end if;
 else
 if coalesce(p_details->>'code','')!~'^[A-Za-z0-9][A-Za-z0-9_-]{0,29}$'or length(coalesce(p_details->>'description',''))>500 then raise exception 'Use a rate code of up to 30 letters, digits, dashes or underscores and a description up to 500 characters.'using errcode='22023';end if;
 if coalesce(p_details->>'adjustment','')!~'^-?[0-9]{1,4}(\.[0-9]{1,2})?$'then raise exception 'Enter an adjustment with up to two decimals.'using errcode='22023';end if;amount:=(p_details->>'adjustment')::numeric;if amount not between -100 and 1000 then raise exception 'Adjustment must be between -100%% and 1000%%.'using errcode='22023';end if;
 if p_id is null then insert into public.rate_plans(tenant_id,property_id,name,code,adjustment_percent,description)values(tenant,p_property,trim(p_details->>'name'),upper(p_details->>'code'),amount,coalesce(p_details->>'description',''))returning id into result_id;
 else update public.rate_plans set name=trim(p_details->>'name'),code=upper(p_details->>'code'),adjustment_percent=amount,description=coalesce(p_details->>'description','')where id=p_id returning id into result_id;end if;
 end if;
 elsif p_section='blocks'then
 select * into room from public.accommodation_units where id=(p_details->>'unit_id')::uuid and property_id=p_property for update;
 if not found or not room.active then raise exception 'Choose an active room in this hotel.'using errcode='22023';end if;
 start_day:=(p_details->>'from')::date;end_day:=(p_details->>'to')::date;
 if start_day is null or end_day is null or start_day<day or end_day<=start_day or end_day-start_day>365 then raise exception 'Choose a block of 1–365 nights starting today or later.'using errcode='22023';end if;
 if length(trim(coalesce(p_details->>'reason','')))not between 3 and 500 then raise exception 'Give a block reason of 3–500 characters.'using errcode='22023';end if;
 result_id:=public.create_inventory_block(room.id,start_day,end_day,trim(p_details->>'reason'));
 else
 select * into hold from public.unit_holds where id=p_id and property_id=p_property and kind='block';if not found then raise exception 'Block not found in this hotel.'using errcode='22023';end if;
 perform 1 from public.accommodation_units where id=hold.unit_id for update;
 select * into hold from public.unit_holds where id=p_id for update;
 if hold.version is distinct from p_version then raise exception 'This block changed. Refresh before releasing it.'using errcode='40001';end if;
 if not hold.active then raise exception 'This block is already released.'using errcode='22023';end if;
 if length(trim(coalesce(p_details->>'reason','')))not between 3 and 500 then raise exception 'Give a release reason of 3–500 characters.'using errcode='22023';end if;
 update public.unit_holds set active=false where id=hold.id;result_id:=hold.id;
 insert into public.inventory_events(tenant_id,property_id,entity,entity_id,action,actor_id,details)values(tenant,p_property,'blocks',hold.id,'released',auth.uid(),jsonb_build_object('reason',trim(p_details->>'reason')));
 end if;
 insert into public.inventory_commands(tenant_id,property_id,request_id,action,entity_id,payload,result_id)values(tenant,p_property,p_request,p_section,p_id,p_details,result_id);return result_id;
end $$;
revoke all on function public.inventory_save(uuid,uuid,text,uuid,integer,jsonb)from public,anon;
grant execute on function public.inventory_save(uuid,uuid,text,uuid,integer,jsonb)to authenticated;
