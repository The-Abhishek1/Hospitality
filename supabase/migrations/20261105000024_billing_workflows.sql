-- Financial writes share the lock order reservation -> folio -> payment.
create sequence public.billing_entry_sequence;
revoke all on sequence public.billing_entry_sequence from public,anon,authenticated;
alter table public.folio_items add column entry_order bigint not null default nextval('public.billing_entry_sequence');
alter table public.payments add column entry_order bigint not null default nextval('public.billing_entry_sequence');
alter table public.refunds add column entry_order bigint not null default nextval('public.billing_entry_sequence');
alter table public.invoices add column snapshot jsonb;
create table public.credit_note_counters(property_id uuid primary key references public.properties(id) on delete cascade,last_number int not null default 0);
create table public.credit_notes(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,property_id uuid not null,folio_id uuid not null,invoice_id uuid not null references public.invoices(id),
 refund_id uuid unique references public.refunds(id),number text not null,amount numeric(12,2) not null check(amount>0),currency char(3) not null,reason text not null,
 snapshot jsonb not null,issued_by uuid references public.profiles(id),issued_at timestamptz not null default now(),entry_order bigint not null default nextval('public.billing_entry_sequence'),
 unique(property_id,number),foreign key(folio_id,property_id) references public.folios(id,property_id),foreign key(property_id,tenant_id) references public.properties(id,tenant_id)
);
create table public.billing_events(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,property_id uuid not null,reservation_id uuid,request_id uuid not null,action text not null,payload jsonb not null,
 result_id uuid,actor_id uuid references public.profiles(id),created_at timestamptz not null default now(),unique(property_id,request_id),
 foreign key(reservation_id,property_id) references public.reservations(id,property_id),foreign key(property_id,tenant_id) references public.properties(id,tenant_id)
);
create table public.night_audit_runs(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,property_id uuid not null,request_id uuid not null,business_date date not null,
 summary jsonb not null,run_by uuid references public.profiles(id),run_at timestamptz not null default now(),unique(property_id,request_id),
 foreign key(property_id,tenant_id) references public.properties(id,tenant_id)
);
alter table public.credit_note_counters enable row level security;
alter table public.credit_notes enable row level security;
alter table public.billing_events enable row level security;
alter table public.night_audit_runs enable row level security;
create policy credit_notes_read on public.credit_notes for select to authenticated using(private.has_permission(property_id,'finance.read') or private.has_permission(property_id,'billing.manage'));
create policy billing_events_read on public.billing_events for select to authenticated using(private.has_permission(property_id,'finance.read') or private.has_permission(property_id,'billing.manage'));
create policy night_audit_runs_read on public.night_audit_runs for select to authenticated using(private.has_permission(property_id,'finance.read') or private.has_permission(property_id,'billing.manage'));

create function private.billing_amount(p_amount numeric,p_signed boolean default false) returns void
language plpgsql immutable set search_path='' as $$
begin
 if p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount=0 or (not p_signed and p_amount<0) or abs(p_amount)>9999999999.99 or round(p_amount,2)<>p_amount then
 raise exception 'Enter a non-zero amount with at most two decimal places.' using errcode='22023';end if;
end $$;
create function private.billing_lock(p_res uuid) returns public.folios
language plpgsql security definer set search_path='' as $$
declare f public.folios;fid uuid;
begin
 perform 1 from public.reservations where id=p_res for update;
 if not found then raise exception 'Reservation not found.' using errcode='22023';end if;
 fid:=private.ensure_folio(p_res);select * into f from public.folios where id=fid for update;return f;
end $$;
create or replace function private.folio_balance_raw(f uuid) returns numeric
language sql stable security definer set search_path='' as $$
 select coalesce((select sum(amount) from public.folio_items where folio_id=f),0)
 -coalesce((select sum(amount) from public.payments where folio_id=f),0)
 +coalesce((select sum(r.amount) from public.refunds r join public.payments p on p.id=r.payment_id where p.folio_id=f),0)
 -coalesce((select sum(amount) from public.credit_notes where folio_id=f),0)
$$;

create or replace function private.post_room_nights(p_res uuid,p_through date) returns uuid
language plpgsql security definer set search_path='' as $$
declare r public.reservations;f public.folios;d date;nightly numeric;nights int;amount numeric;remainder int;
begin
 f:=private.billing_lock(p_res);select * into r from public.reservations where id=p_res;
 if f.status='closed' then return f.id;end if;
 nights:=r.check_out-r.check_in;nightly:=trunc(r.total_amount/nights,2);remainder:=round((r.total_amount-nightly*nights)*100)::int;
 for d in select g::date from generate_series(r.check_in,least(p_through,r.check_out-1),interval '1 day')g loop
 amount:=nightly+case when d-r.check_in<remainder then 0.01 else 0 end;
 insert into public.folio_items(tenant_id,property_id,folio_id,kind,description,amount,business_date,posted_by)
 values(r.tenant_id,r.property_id,f.id,'room','Room charge '||d,amount,d,auth.uid()) on conflict(folio_id,business_date) where kind='room' do nothing;
 end loop;return f.id;
end $$;

-- Close the serving/creation race with invoice finalization, including portal orders.
create function private.guard_room_order_billing() returns trigger
language plpgsql security definer set search_path='' as $$
declare f public.folios;r public.reservations;
begin
 if new.reservation_id is null then return new;end if;
 select * into r from public.reservations where id=new.reservation_id for update;
 if not found or r.status<>'checked_in' then raise exception 'Room orders require an in-house guest.' using errcode='22023';end if;
 f:=private.billing_lock(r.id);
 if f.status='closed' then raise exception 'This folio is invoiced. New room orders cannot be added.' using errcode='22023';end if;return new;
end $$;
create trigger orders_billing_guard before insert on public.orders for each row execute function private.guard_room_order_billing();
create function private.guard_folio_item() returns trigger
language plpgsql security definer set search_path='' as $$
declare f public.folios;rid uuid;
begin
 select reservation_id into rid from public.folios where id=new.folio_id;f:=private.billing_lock(rid);
 if f.status='closed' then raise exception 'Invoiced folios cannot receive new charges.' using errcode='22023';end if;return new;
end $$;
create trigger folio_item_billing_guard before insert on public.folio_items for each row execute function private.guard_folio_item();

create or replace function public.collect_folio_payment(p_folio uuid,p_amount numeric,p_method text,p_reference text default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare f public.folios;rid uuid;id uuid;
begin
 select reservation_id,property_id into rid,id from public.folios where public.folios.id=p_folio;
 if rid is null or not private.has_permission(id,'billing.manage') then raise exception 'not permitted' using errcode='42501';end if;
 f:=private.billing_lock(rid);if f.status<>'open' then raise exception 'This folio is already invoiced.' using errcode='22023';end if;
 perform private.billing_amount(p_amount);
 if p_method is null or p_method not in ('cash','card','upi','bank_transfer','other') or length(coalesce(p_reference,''))>200 then raise exception 'Choose a valid payment method and reference.' using errcode='22023';end if;
 insert into public.payments(tenant_id,property_id,folio_id,amount,method,reference,collected_by) values(f.tenant_id,f.property_id,f.id,p_amount,p_method,nullif(trim(p_reference),''),auth.uid()) returning public.payments.id into id;return id;
end $$;

create or replace function public.post_folio_charge(p_reservation uuid,p_description text,p_amount numeric) returns void
language plpgsql security definer set search_path='' as $$
declare r public.reservations;f public.folios;tz text;
begin
 select * into r from public.reservations where id=p_reservation;
 if not found or not private.has_permission(r.property_id,'billing.manage') then raise exception 'not permitted' using errcode='42501';end if;
 if p_amount<0 and not private.has_permission(r.property_id,'finance.write') then raise exception 'credits need finance.write' using errcode='42501';end if;
 perform private.billing_amount(p_amount,true);
 if length(trim(coalesce(p_description,''))) not between 3 and 300 then raise exception 'Enter a description (3–300 characters).' using errcode='22023';end if;
 f:=private.billing_lock(r.id);if f.status='closed' then raise exception 'This folio is invoiced. Charges are locked.' using errcode='22023';end if;
 select timezone into tz from public.properties where id=r.property_id;
 insert into public.folio_items(tenant_id,property_id,folio_id,kind,description,amount,business_date,posted_by) values(r.tenant_id,r.property_id,f.id,'adjustment',trim(p_description),p_amount,(now() at time zone tz)::date,auth.uid());
end $$;

create or replace function public.refund_payment(p_payment uuid,p_amount numeric,p_reason text) returns uuid
language plpgsql security definer set search_path='' as $$
declare p public.payments;f public.folios;inv public.invoices;done numeric;id uuid;seq int;credit_total numeric;tz text;
begin
 select * into p from public.payments where public.payments.id=p_payment;
 if not found or not private.has_permission(p.property_id,'finance.write') then raise exception 'not permitted' using errcode='42501';end if;
 if p.folio_id is not null then select * into f from public.folios where public.folios.id=p.folio_id;f:=private.billing_lock(f.reservation_id);
 else perform 1 from public.orders where public.orders.id=p.order_id for update;end if;
 select * into p from public.payments where public.payments.id=p_payment for update;
 perform private.billing_amount(p_amount);
 select coalesce(sum(amount),0) into done from public.refunds where payment_id=p.id;
 if p_amount>p.amount-done then raise exception 'Refund exceeds the remaining refundable payment.' using errcode='22023';end if;
 if length(trim(coalesce(p_reason,''))) not between 3 and 500 then raise exception 'Enter a refund reason (3–500 characters).' using errcode='22023';end if;
 if f.status='closed' then
  select * into inv from public.invoices where folio_id=f.id;
  select coalesce(sum(amount),0) into credit_total from public.credit_notes where invoice_id=inv.id;
  if not found or inv.id is null or p_amount>inv.total-credit_total then raise exception 'Refund exceeds the uncredited invoice total.' using errcode='22023';end if;
 end if;
 insert into public.refunds(tenant_id,property_id,payment_id,amount,reason,refunded_by) values(p.tenant_id,p.property_id,p.id,p_amount,trim(p_reason),auth.uid()) returning public.refunds.id into id;
 if f.status='closed' then
  select timezone into tz from public.properties where public.properties.id=p.property_id;
  insert into public.credit_note_counters(property_id,last_number) values(p.property_id,1) on conflict(property_id) do update set last_number=public.credit_note_counters.last_number+1 returning last_number into seq;
  insert into public.credit_notes(tenant_id,property_id,folio_id,invoice_id,refund_id,number,amount,currency,reason,snapshot,issued_by)
  values(p.tenant_id,p.property_id,f.id,inv.id,id,'CN-'||to_char(now() at time zone tz,'YYYY')||'-'||lpad(seq::text,6,'0'),p_amount,inv.currency,trim(p_reason),jsonb_build_object('invoice_number',inv.number,'invoice_snapshot',inv.snapshot,'amount',p_amount,'reason',trim(p_reason)),auth.uid());
 end if;return id;
end $$;

create or replace function public.finalize_invoice(p_folio uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare f public.folios;r public.reservations;p public.properties;id uuid;seq int;total numeric;snap jsonb;
begin
 select * into f from public.folios where public.folios.id=p_folio;
 if not found or not private.has_permission(f.property_id,'billing.manage') then raise exception 'not permitted' using errcode='42501';end if;
 f:=private.billing_lock(f.reservation_id);select public.invoices.id into id from public.invoices where folio_id=f.id;
 if id is not null then return id;end if;
 if f.status<>'open' then raise exception 'This folio is closed.' using errcode='22023';end if;
 select * into r from public.reservations where public.reservations.id=f.reservation_id;
 if r.status not in ('checked_in','checked_out') then raise exception 'Only an in-house or checked-out stay can be invoiced.' using errcode='22023';end if;
 if exists(select 1 from public.orders where reservation_id=r.id and status in ('placed','preparing','ready')) then raise exception 'Resolve or serve pending room orders before invoicing.' using errcode='22023';end if;
 perform private.post_room_nights(r.id,r.check_out-1);
 if private.folio_balance_raw(f.id)<>0 then raise exception 'Settle the folio to zero before issuing an invoice.' using errcode='22023';end if;
 select * into p from public.properties where public.properties.id=f.property_id;
 select coalesce(sum(amount),0) into total from public.folio_items where folio_id=f.id;
 if total<0 then raise exception 'A negative charge total cannot be invoiced.' using errcode='22023';end if;
 snap:=jsonb_build_object('property',jsonb_build_object('name',p.name,'address',p.address,'city',p.city,'country_code',p.country_code,'email',p.contact_email,'phone',p.contact_phone,'timezone',p.timezone),
 'guest',(select jsonb_build_object('name',full_name,'phone',phone,'email',email) from public.guests where public.guests.id=r.guest_id),
 'stay',jsonb_build_object('id',r.id,'check_in',r.check_in,'check_out',r.check_out),
 'items',coalesce((select jsonb_agg(jsonb_build_object('description',description,'kind',kind,'amount',amount,'date',business_date) order by business_date,entry_order) from public.folio_items where folio_id=f.id),'[]'::jsonb),
 'payments',coalesce((select sum(amount) from public.payments where folio_id=f.id),0),'refunds',coalesce((select sum(rf.amount) from public.refunds rf join public.payments py on py.id=rf.payment_id where py.folio_id=f.id),0),'total',total,'currency',f.currency,'issued_at',now());
 insert into public.invoice_counters(property_id,last_number) values(f.property_id,1) on conflict(property_id) do update set last_number=public.invoice_counters.last_number+1 returning last_number into seq;
 insert into public.invoices(tenant_id,property_id,folio_id,number,total,currency,issued_by,snapshot) values(f.tenant_id,f.property_id,f.id,'INV-'||to_char(now() at time zone p.timezone,'YYYY')||'-'||lpad(seq::text,6,'0'),total,f.currency,auth.uid(),snap) returning public.invoices.id into id;
 update public.folios set status='closed',closed_at=now() where public.folios.id=f.id;return id;
end $$;

create function public.billing_action(p_property uuid,p_reservation uuid,p_request uuid,p_action text,p_details jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.reservations;f public.folios;e public.billing_events;id uuid;amount numeric;balance numeric;payment public.payments;
begin
 if p_action='refund' then
  if not private.has_permission(p_property,'finance.write') then raise exception 'not permitted' using errcode='42501';end if;
 elsif not private.has_permission(p_property,'billing.manage') then raise exception 'not permitted' using errcode='42501';end if;
 if p_details is null or jsonb_typeof(p_details)<>'object' then raise exception 'Invalid billing details.' using errcode='22023';end if;
 if p_request is null then raise exception 'Reload this form and try again.' using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_property::text||p_request::text,0));
 select * into e from public.billing_events where property_id=p_property and request_id=p_request;
 if found then
  if e.reservation_id is distinct from p_reservation or e.action<>p_action or e.payload is distinct from p_details then raise exception 'This request was already used for different details. Reload the form.' using errcode='22023';end if;
  return jsonb_build_object('id',e.result_id,'action',e.action);
 end if;
 select * into r from public.reservations where public.reservations.id=p_reservation and property_id=p_property for update;
 if not found then raise exception 'Reservation not found in this hotel.' using errcode='22023';end if;
 f:=private.billing_lock(r.id);balance:=private.folio_balance_raw(f.id);
 if p_details?'expected_balance' and balance<>(p_details->>'expected_balance')::numeric then raise exception 'The balance changed. Refresh and review the latest activity.' using errcode='40001';end if;
 if p_action='post_rooms' then
  if r.status<>'checked_in' then raise exception 'Room nights can be posted here for in-house guests only.' using errcode='22023';end if;
  id:=public.post_room_charges(r.id);
 elsif p_action='payment' then
  amount:=(p_details->>'amount')::numeric;perform private.billing_amount(amount);
  if r.status not in ('confirmed','checked_in','checked_out') then raise exception 'Payments cannot be added to a cancelled or no-show stay.' using errcode='22023';end if;
  if amount>greatest(0,balance) and coalesce((p_details->>'allow_credit')::boolean,false)=false then raise exception 'This payment exceeds the posted balance. Confirm a deposit or overpayment explicitly.' using errcode='22023';end if;
  id:=public.collect_folio_payment(f.id,amount,p_details->>'method',p_details->>'reference');
 elsif p_action in ('charge','credit') then
  amount:=(p_details->>'amount')::numeric;perform private.billing_amount(amount);
  if p_action='credit' then amount:=-amount;end if;
  perform public.post_folio_charge(r.id,p_details->>'description',amount);
  select public.folio_items.id into id from public.folio_items where folio_id=f.id order by entry_order desc limit 1;
 elsif p_action='refund' then
  select * into payment from public.payments where public.payments.id=(p_details->>'payment_id')::uuid and folio_id=f.id;
  if not found then raise exception 'Select a payment recorded on this folio.' using errcode='22023';end if;
  id:=public.refund_payment(payment.id,(p_details->>'amount')::numeric,p_details->>'reason');
 elsif p_action='invoice' then id:=public.finalize_invoice(f.id);
 else raise exception 'Unknown billing action.' using errcode='22023';end if;
 insert into public.billing_events(tenant_id,property_id,reservation_id,request_id,action,payload,result_id,actor_id) values(r.tenant_id,r.property_id,r.id,p_request,p_action,p_details,id,auth.uid());
 return jsonb_build_object('id',id,'action',p_action);
end $$;

create function private.run_billing_audit(p_property uuid,p_date date,p_request uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p public.properties;r record;f public.folios;before_sum numeric;after_sum numeric;posted numeric:=0;processed int:=0;noshow int;result jsonb;previous public.night_audit_runs;
begin
 if not private.has_permission(p_property,'billing.manage') then raise exception 'not permitted' using errcode='42501';end if;
 select * into p from public.properties where id=p_property;
 if p_date is null or p_date<'2000-01-01' or p_date>(now() at time zone p.timezone)::date or p_request is null then raise exception 'Choose a valid business date up to today.' using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('night-audit:'||p_property::text,0));
 select * into previous from public.night_audit_runs where property_id=p_property and request_id=p_request;
 if found then if previous.business_date<>p_date then raise exception 'Audit request already used for another date.' using errcode='22023';end if;return previous.summary;end if;
 for r in select id from public.reservations where property_id=p_property and status='checked_in' and check_in<=p_date and p_date<check_out order by id loop
  f:=private.billing_lock(r.id);select coalesce(sum(amount),0) into before_sum from public.folio_items where folio_id=f.id and kind='room';
  perform private.post_room_nights(r.id,p_date);
  select coalesce(sum(amount),0) into after_sum from public.folio_items where folio_id=f.id and kind='room';
  posted:=posted+after_sum-before_sum;processed:=processed+1;
 end loop;
 select count(*) into noshow from public.reservations where property_id=p_property and status='confirmed' and check_in<=p_date;
 result:=jsonb_build_object('reservations_processed',processed,'room_revenue_posted',posted,'no_show_candidates',noshow);
 insert into public.night_audits(tenant_id,property_id,business_date,summary,run_by) values(p.tenant_id,p.id,p_date,result||jsonb_build_object('run_count',1,'last_run_posted',posted),auth.uid())
 on conflict(property_id,business_date) do update set summary=excluded.summary||jsonb_build_object('room_revenue_posted',coalesce((public.night_audits.summary->>'room_revenue_posted')::numeric,0)+posted,'run_count',coalesce((public.night_audits.summary->>'run_count')::int,1)+1),run_by=auth.uid(),run_at=now();
 insert into public.night_audit_runs(tenant_id,property_id,request_id,business_date,summary,run_by) values(p.tenant_id,p.id,p_request,p_date,result,auth.uid());return result;
end $$;
create or replace function public.run_night_audit(p_property uuid,p_date date) returns jsonb
language plpgsql security definer set search_path='' as $$
begin return private.run_billing_audit(p_property,p_date,pg_catalog.gen_random_uuid());end $$;
create function public.billing_run_audit(p_property uuid,p_date date,p_request uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin return private.run_billing_audit(p_property,p_date,p_request);end $$;

revoke all on function private.billing_amount(numeric,boolean),private.billing_lock(uuid),private.guard_room_order_billing(),private.guard_folio_item(),private.run_billing_audit(uuid,date,uuid) from public,anon,authenticated;
revoke all on function public.billing_action(uuid,uuid,uuid,text,jsonb),public.billing_run_audit(uuid,date,uuid) from public,anon;
grant execute on function public.billing_action(uuid,uuid,uuid,text,jsonb),public.billing_run_audit(uuid,date,uuid) to authenticated;
