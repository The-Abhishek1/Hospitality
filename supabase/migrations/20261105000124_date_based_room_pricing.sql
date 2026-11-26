-- Date-specific base nightly prices. Existing reservations retain their agreed total.
create table public.room_date_prices(
 tenant_id uuid not null,property_id uuid not null,type_id uuid not null,night date not null,
 amount numeric(12,2)not null check(amount>=0),label text not null default ''check(length(label)<=120),
 updated_by uuid references public.profiles(id),updated_at timestamptz not null default now(),
 primary key(type_id,night),foreign key(type_id,property_id)references public.accommodation_types(id,property_id)on delete cascade,
 foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade
);
alter table public.room_date_prices enable row level security;
revoke all on public.room_date_prices from public,anon,authenticated;
grant select on public.room_date_prices to authenticated;
create policy room_date_prices_read on public.room_date_prices for select to authenticated using(private.has_property_access(property_id));
create table private.room_pricing_versions(property_id uuid primary key references public.properties(id)on delete cascade,version integer not null default 0);
create table private.room_pricing_commands(
 property_id uuid not null references public.properties(id)on delete cascade,request_id uuid not null,payload jsonb not null,result jsonb not null,
 actor_id uuid references public.profiles(id),created_at timestamptz not null default clock_timestamp(),primary key(property_id,request_id)
);
revoke all on private.room_pricing_versions,private.room_pricing_commands from public,anon,authenticated,service_role;

create function private.bump_room_pricing_version()returns trigger language plpgsql security definer set search_path=''as $$
begin
 if not exists(select 1 from public.properties where id=coalesce(new.property_id,old.property_id))then return coalesce(new,old);end if;
 if tg_op='UPDATE'and to_jsonb(new)->'base_rate'is not distinct from to_jsonb(old)->'base_rate'and to_jsonb(new)->'adjustment_percent'is not distinct from to_jsonb(old)->'adjustment_percent'then return new;end if;
 insert into private.room_pricing_versions(property_id,version)values(coalesce(new.property_id,old.property_id),1)
 on conflict(property_id)do update set version=private.room_pricing_versions.version+1;
 return coalesce(new,old);
end $$;
create trigger room_type_pricing_version after insert or update of base_rate or delete on public.accommodation_types for each row execute function private.bump_room_pricing_version();
create trigger rate_plan_pricing_version after insert or update of adjustment_percent or delete on public.rate_plans for each row execute function private.bump_room_pricing_version();

create function public.room_pricing_workspace(p_property uuid,p_start date default null,p_type uuid default null,p_page integer default 1)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare prop public.properties;today date;first_day date;pg integer:=greatest(1,least(100000,coalesce(p_page,1)));result jsonb;
begin
 if not private.has_permission(p_property,'inventory.manage')then raise exception 'Inventory management access required.'using errcode='42501';end if;
 select *into prop from public.properties where id=p_property;today:=(now()at time zone prop.timezone)::date;first_day:=coalesce(p_start,today);
 if first_day<'2000-01-01'or first_day>'2100-12-18'then raise exception 'Choose a valid calendar start date.'using errcode='22023';end if;
 if p_type is not null and not exists(select 1 from public.accommodation_types where id=p_type and property_id=p_property)then raise exception 'Room type not found in this hotel.'using errcode='22023';end if;
 with types as materialized(select *from public.accommodation_types where property_id=p_property and(p_type is null or id=p_type))
 select jsonb_build_object('total',(select count(*)from types),'rows',coalesce((select jsonb_agg(to_jsonb(x)order by x.name,x.id)from(
  select t.id,t.name,t.base_rate,(select jsonb_agg(jsonb_build_object('night',first_day+n,'amount',coalesce(o.amount,t.base_rate),'custom',o.type_id is not null,'label',coalesce(o.label,''))order by n)
   from generate_series(0,13)n left join public.room_date_prices o on o.type_id=t.id and o.night=first_day+n)as days
  from types t order by name,id limit 10 offset(pg-1)*10)x),'[]'::jsonb))into result;
 return result||jsonb_build_object('day',today,'latest',least(today+730,'2100-12-31'::date),'start',first_day,'page',pg,'currency',prop.currency,'timezone',prop.timezone,
  'version',coalesce((select version from private.room_pricing_versions where property_id=p_property),0),
  'types',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'base_rate',base_rate)order by name,id)from public.accommodation_types where property_id=p_property),'[]'::jsonb),
  'history',coalesce((select jsonb_agg(x order by x.created_at desc)from(select c.created_at,c.result,c.payload,pr.full_name as actor_name from private.room_pricing_commands c left join public.profiles pr on pr.id=c.actor_id where c.property_id=p_property order by c.created_at desc,c.request_id desc limit 10)x),'[]'::jsonb));
end $$;

create function public.room_pricing_save(p_property uuid,p_request uuid,p_version integer,p_type uuid,p_from date,p_to date,p_weekdays integer,p_amount numeric default null,p_reset boolean default false,p_label text default '')returns jsonb
language plpgsql security definer set search_path=''as $$
declare prop public.properties;today date;revision integer;payload jsonb;previous private.room_pricing_commands;result jsonb;affected integer;
begin
 if not private.has_permission(p_property,'inventory.manage')then raise exception 'Inventory management access required.'using errcode='42501';end if;
 if p_request is null or p_version is null or p_reset is null then raise exception 'Refresh the pricing calendar before saving.'using errcode='22023';end if;
 select *into prop from public.properties where id=p_property for update;
 perform private.staff_share(p_property);
 today:=(now()at time zone prop.timezone)::date;
 perform 1 from public.accommodation_types where id=p_type and property_id=p_property for share;
 if not found then raise exception 'Choose a room type in this hotel.'using errcode='22023';end if;
 if p_from is null or p_to is null or p_from<today or p_to<p_from or p_to-p_from>365 or p_to>least(today+730,'2100-12-31'::date)then raise exception 'Choose today or future nights, up to 366 nights per update and two years ahead. The last night is included.'using errcode='22023';end if;
 if p_weekdays is null or p_weekdays not between 1 and 127 then raise exception 'Choose at least one day of the week.'using errcode='22023';end if;
 if not p_reset and(p_amount is null or p_amount::text in('NaN','Infinity','-Infinity')or p_amount<0 or p_amount>9999999999.99 or round(p_amount,2)<>p_amount)then raise exception 'Enter a non-negative nightly price with up to two decimal places.'using errcode='22023';end if;
 if p_label is null or length(p_label)>120 then raise exception 'Keep the price label under 120 characters.'using errcode='22023';end if;
 payload:=jsonb_build_object('type',p_type,'from',p_from,'to',p_to,'weekdays',p_weekdays,'amount',case when not p_reset then p_amount end,'reset',p_reset,'label',trim(p_label),'version',p_version);
 select *into previous from private.room_pricing_commands where property_id=p_property and request_id=p_request;
 if found then
  if previous.payload is distinct from payload then raise exception 'This request was already used with different prices. Refresh before saving.'using errcode='22023';end if;
  return previous.result;
 end if;
 insert into private.room_pricing_versions(property_id)values(p_property)on conflict do nothing;
 select version into revision from private.room_pricing_versions where property_id=p_property for update;
 if revision<>p_version then raise exception 'Room prices changed in another session. Refresh and review the calendar before saving.'using errcode='40001';end if;
 select count(*)into affected from generate_series(0,p_to-p_from)n where(p_weekdays&(1<<extract(dow from p_from+n)::integer))<>0;
 if affected=0 then raise exception 'The selected date range contains none of the chosen weekdays.'using errcode='22023';end if;
 if p_reset then
  delete from public.room_date_prices where type_id=p_type and night between p_from and p_to and(p_weekdays&(1<<extract(dow from night)::integer))<>0;
 else
  insert into public.room_date_prices(tenant_id,property_id,type_id,night,amount,label,updated_by)
  select prop.tenant_id,p_property,p_type,p_from+n,p_amount,trim(p_label),auth.uid()from generate_series(0,p_to-p_from)n where(p_weekdays&(1<<extract(dow from p_from+n)::integer))<>0
  on conflict(type_id,night)do update set amount=excluded.amount,label=excluded.label,updated_by=excluded.updated_by,updated_at=clock_timestamp();
 end if;
 update private.room_pricing_versions set version=version+1 where property_id=p_property returning version into revision;
 result:=jsonb_build_object('nights',affected,'version',revision,'reset',p_reset);
 insert into private.room_pricing_commands(property_id,request_id,payload,result,actor_id)values(p_property,p_request,payload,result,auth.uid());
 return result;
end $$;

create function private.room_nightly_prices(p_property uuid,p_type uuid,p_in date,p_out date,p_rate uuid default null)
returns table(night date,amount numeric,custom boolean,label text)
language plpgsql stable security definer set search_path=''as $$
declare t public.accommodation_types;adjustment numeric:=0;
begin
 select *into t from public.accommodation_types where id=p_type and property_id=p_property;
 if t.id is null then raise exception 'Room type not found.'using errcode='22023';end if;
 if p_rate is not null then
  select adjustment_percent into adjustment from public.rate_plans where id=p_rate and property_id=p_property;
  if not found then raise exception 'Rate plan not found.'using errcode='22023';end if;
 end if;
 -- Distribute fractional cents while preserving the previously agreed rounding
 -- of the full stay total (rather than rounding every discounted night upward).
 return query with raw as(
  select n,coalesce(o.amount,t.base_rate)*(1+adjustment/100)as value,o.type_id is not null as custom,coalesce(o.label,'')as label
  from generate_series(0,p_out-p_in-1)n left join public.room_date_prices o on o.type_id=p_type and o.night=p_in+n
 ),cumulative as(select x.*,round(sum(x.value)over(order by x.n),2)as running from raw x)
 select p_in+x.n,x.running-coalesce(lag(x.running)over(order by x.n),0),x.custom,x.label from cumulative x order by x.n;
end $$;

create or replace function private.frontdesk_price(p_property uuid,p_type uuid,p_in date,p_out date,p_adults integer,p_children integer,p_rate uuid)returns numeric
language plpgsql security definer set search_path=''as $$
declare t public.accommodation_types;total numeric;
begin
 if p_in is null or p_out is null or p_out<=p_in or p_out-p_in>365 then raise exception 'Choose a stay of 1 to 365 nights.'using errcode='22023';end if;
 -- PostgREST executes STABLE quote RPCs in read-only transactions. Quotes use
 -- that transaction's snapshot; write transactions lock prices through booking.
 if current_setting('transaction_read_only')='off'then
  perform 1 from public.properties where id=p_property for share;
  perform 1 from public.accommodation_types where id=p_type and property_id=p_property for share;
  if p_rate is not null then perform 1 from public.rate_plans where id=p_rate and property_id=p_property for share;end if;
 end if;
 select *into t from public.accommodation_types where id=p_type and property_id=p_property;
 if not found then raise exception 'Room type not found.'using errcode='22023';end if;
 if p_adults is null or p_children is null or p_adults<1 or p_children<0 or p_adults+p_children>t.max_occupancy then raise exception 'Guest count exceeds the room type capacity.'using errcode='22023';end if;
 select sum(x.amount)into total from private.room_nightly_prices(p_property,p_type,p_in,p_out,p_rate)x;
 if total>9999999999.99 then raise exception 'The stay total exceeds the supported amount. Choose a shorter stay.'using errcode='22023';end if;
 return total;
end $$;

-- Keep existing validation, idempotency and allocation for older API callers.
do $$declare definition text;needle text:='v_total := coalesce(p_total, round(v_type.base_rate * (p_check_out - p_check_in) * (1 + v_adj / 100), 2));';begin
 select pg_get_functiondef('private.create_reservation_core(uuid,uuid,uuid,date,date,integer,integer,uuid,text,text,uuid,numeric)'::regprocedure)into definition;
 if strpos(definition,needle)=0 then raise exception 'Reservation pricing integration requires review.';end if;
 execute replace(definition,needle,'v_total := case when p_total is not null then p_total else private.frontdesk_price(p_property,p_type,p_check_in,p_check_out,p_adults,p_children,p_rate_plan)end;');
end $$;

-- Keep the public function identity intact for prepared API statements.
do $$declare definition text;begin
 select pg_get_functiondef('public.frontdesk_quote(uuid,uuid,date,date,integer,integer,uuid,uuid)'::regprocedure)into definition;
 execute replace(definition,'public.frontdesk_quote(','private.frontdesk_quote_before_date_prices(');
end $$;
revoke all on function private.frontdesk_quote_before_date_prices(uuid,uuid,date,date,integer,integer,uuid,uuid)from public,anon,authenticated,service_role;
create or replace function public.frontdesk_quote(p_property uuid,p_type uuid,p_in date,p_out date,p_adults integer,p_children integer,p_rate uuid default null,p_exclude uuid default null)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare result jsonb;
begin
 result:=private.frontdesk_quote_before_date_prices(p_property,p_type,p_in,p_out,p_adults,p_children,p_rate,p_exclude);
 return result||jsonb_build_object('nightly',(select jsonb_agg(jsonb_build_object('night',night,'amount',amount,'custom',custom,'label',label)order by night)from private.room_nightly_prices(p_property,p_type,p_in,p_out,p_rate)));
end $$;

-- Snapshot nightly amounts at booking. Rates edited later never rewrite a stay.
alter table public.reservations add column nightly_pricing boolean not null default false;
alter table public.reservations alter column nightly_pricing set default true;
create table public.reservation_nightly_prices(
 tenant_id uuid not null,property_id uuid not null,reservation_id uuid not null references public.reservations(id)on delete cascade,
 night date not null,type_id uuid not null,amount numeric(12,2)not null check(amount>=0),source text not null check(source in('base','calendar','agreed_total')),
 primary key(reservation_id,night),foreign key(type_id,property_id)references public.accommodation_types(id,property_id),
 foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade
);
alter table public.reservation_nightly_prices enable row level security;
revoke all on public.reservation_nightly_prices from public,anon,authenticated;
grant select on public.reservation_nightly_prices to authenticated;
create policy reservation_nightly_prices_read on public.reservation_nightly_prices for select to authenticated using(private.has_permission(property_id,'reservations.read')or private.has_permission(property_id,'finance.read')or private.has_permission(property_id,'billing.manage'));
create function private.capture_reservation_nightly_prices(p_reservation uuid,p_type uuid)returns void
language plpgsql security definer set search_path=''as $$
declare r public.reservations;quoted numeric;count_nights integer;nightly numeric;remainder integer;
begin
 select *into r from public.reservations where id=p_reservation;
 if r.id is null then return;end if;
 count_nights:=r.check_out-r.check_in;
 select sum(amount)into quoted from private.room_nightly_prices(r.property_id,p_type,r.check_in,r.check_out,r.rate_plan_id);
 delete from public.reservation_nightly_prices where reservation_id=r.id;
 if quoted=r.total_amount and r.source<>'ota'then
  insert into public.reservation_nightly_prices(tenant_id,property_id,reservation_id,night,type_id,amount,source)
  select r.tenant_id,r.property_id,r.id,x.night,p_type,x.amount,case when x.custom then'calendar'else'base'end from private.room_nightly_prices(r.property_id,p_type,r.check_in,r.check_out,r.rate_plan_id)x;
 else
  -- External agreed totals and legacy/manual totals are preserved, never repriced.
  nightly:=trunc(r.total_amount/count_nights,2);remainder:=round((r.total_amount-nightly*count_nights)*100)::integer;
  insert into public.reservation_nightly_prices(tenant_id,property_id,reservation_id,night,type_id,amount,source)
  select r.tenant_id,r.property_id,r.id,r.check_in+n,p_type,nightly+case when n<remainder then 0.01 else 0 end,'agreed_total'from generate_series(0,count_nights-1)n;
 end if;
end $$;
create function private.snapshot_room_hold_prices()returns trigger language plpgsql security definer set search_path=''as $$
declare room_type uuid;
begin
 if new.kind='reservation'and new.reservation_id is not null and exists(select 1 from public.reservations where id=new.reservation_id and nightly_pricing)
 and not exists(select 1 from public.reservation_nightly_prices where reservation_id=new.reservation_id)then
  select type_id into room_type from public.accommodation_units where id=new.unit_id;
  perform private.capture_reservation_nightly_prices(new.reservation_id,room_type);
 end if;return new;
end $$;
create trigger room_hold_price_snapshot after insert on public.unit_holds for each row execute function private.snapshot_room_hold_prices();
create function private.refresh_reservation_nightly_prices()returns trigger language plpgsql security definer set search_path=''as $$
declare room_type uuid;
begin
 if exists(select 1 from public.folios f where f.reservation_id=new.id and(f.status='closed'or exists(select 1 from public.folio_items where folio_id=f.id and kind='room')))then
  if (new.check_in,new.check_out,new.rate_plan_id,new.total_amount)is distinct from(old.check_in,old.check_out,old.rate_plan_id,old.total_amount)then raise exception 'Posted room charges cannot be repriced. Review this stay with finance.'using errcode='22023';end if;
  return new;
 end if;
 select u.type_id into room_type from public.unit_holds h join public.accommodation_units u on u.id=h.unit_id where h.reservation_id=new.id and h.active order by h.created_at desc,h.id desc limit 1;
 if room_type is not null then perform private.capture_reservation_nightly_prices(new.id,room_type);end if;return new;
end $$;
create trigger reservation_price_snapshot after update of check_in,check_out,rate_plan_id,total_amount on public.reservations for each row execute function private.refresh_reservation_nightly_prices();

create or replace function private.post_room_nights(p_res uuid,p_through date)returns uuid
language plpgsql security definer set search_path=''as $$
declare r public.reservations;f public.folios;d date;nightly numeric;nights integer;amount numeric;remainder integer;snapshot_count integer;snapshot_total numeric;
begin
 f:=private.billing_lock(p_res);select *into r from public.reservations where id=p_res;
 if f.status='closed'then return f.id;end if;
 nights:=r.check_out-r.check_in;nightly:=trunc(r.total_amount/nights,2);remainder:=round((r.total_amount-nightly*nights)*100)::integer;
 select count(*),sum(x.amount)into snapshot_count,snapshot_total from public.reservation_nightly_prices x where reservation_id=r.id;
 if snapshot_count>0 and(snapshot_count<>nights or snapshot_total<>r.total_amount)then raise exception 'Booked nightly prices are inconsistent. Review this stay before posting room charges.'using errcode='40001';end if;
 for d in select r.check_in+n from generate_series(0,least(p_through,r.check_out-1)-r.check_in)n loop
  if snapshot_count>0 then select x.amount into amount from public.reservation_nightly_prices x where reservation_id=r.id and night=d;
  else amount:=nightly+case when d-r.check_in<remainder then 0.01 else 0 end;end if;
  insert into public.folio_items(tenant_id,property_id,folio_id,kind,description,amount,business_date,posted_by)
  values(r.tenant_id,r.property_id,f.id,'room','Room charge '||d,amount,d,auth.uid())on conflict(folio_id,business_date)where kind='room'do nothing;
 end loop;return f.id;
end $$;

revoke all on function private.bump_room_pricing_version(),private.room_nightly_prices(uuid,uuid,date,date,uuid),private.capture_reservation_nightly_prices(uuid,uuid),private.snapshot_room_hold_prices(),private.refresh_reservation_nightly_prices()from public,anon,authenticated,service_role;
revoke all on function public.room_pricing_workspace(uuid,date,uuid,integer),public.room_pricing_save(uuid,uuid,integer,uuid,date,date,integer,numeric,boolean,text),public.frontdesk_quote(uuid,uuid,date,date,integer,integer,uuid,uuid)from public,anon;
grant execute on function public.room_pricing_workspace(uuid,date,uuid,integer),public.room_pricing_save(uuid,uuid,integer,uuid,date,date,integer,numeric,boolean,text),public.frontdesk_quote(uuid,uuid,date,date,integer,integer,uuid,uuid)to authenticated;
notify pgrst,'reload schema';
