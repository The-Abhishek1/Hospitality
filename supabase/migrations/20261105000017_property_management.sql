-- Property configuration is managed by tenant owners/admins under existing RLS.
alter table public.properties
  add column address text not null default '' check (length(address)<=1000),
  add column city text not null default '' check (length(city)<=120),
  add column country_code text not null default 'IN' check (country_code ~ '^[A-Z]{2}$'),
  add column contact_email text not null default '' check (length(contact_email)<=254),
  add column contact_phone text not null default '' check (length(contact_phone)<=40),
  add column creation_request_id uuid;
create unique index properties_creation_request on public.properties(tenant_id,creation_request_id) where creation_request_id is not null;
alter table public.properties add constraint properties_currency_format check (currency ~ '^[A-Z]{3}$');

-- Serialize plan checks so simultaneous property creation cannot exceed the cap.
create or replace function private.enforce_property_limit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  perform 1 from public.tenants where id=new.tenant_id for update;
  v := private.entitlement(new.tenant_id,'max_properties');
  if v is not null and (select count(*) from public.properties where tenant_id=new.tenant_id)>=(v #>> '{}')::int then
    raise exception 'property limit reached for current plan' using errcode='53400';
  end if;
  return new;
end $$;

create function private.guard_property_configuration() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.tenant_id is distinct from old.tenant_id then raise exception 'properties cannot move between businesses' using errcode='22023'; end if;
  if new.currency is distinct from old.currency and
    (exists(select 1 from public.reservations where property_id=old.id)
     or exists(select 1 from public.payments where property_id=old.id)
     or exists(select 1 from public.orders where property_id=old.id)) then
    raise exception 'currency is locked after bookings or orders have been created' using errcode='22023';
  end if;
  return new;
end $$;
revoke all on function private.guard_property_configuration() from public,anon,authenticated;
create trigger property_configuration_guard before update of tenant_id,currency on public.properties
for each row execute function private.guard_property_configuration();

create function public.create_property(p_tenant uuid,p_request uuid,p_name text,p_type text,p_timezone text,p_currency text,p_details jsonb default '{}') returns uuid
language plpgsql security invoker set search_path = '' as $$
declare v_id uuid;
begin
  if not private.is_tenant_admin(p_tenant) then raise exception 'not permitted' using errcode='42501'; end if;
  if p_request is null then raise exception 'creation request required' using errcode='22023'; end if;
  perform 1 from public.tenants where id=p_tenant for update;
  select id into v_id from public.properties where tenant_id=p_tenant and creation_request_id=p_request;
  if found then return v_id; end if;
  insert into public.properties(tenant_id,creation_request_id,name,property_type,timezone,currency,address,city,country_code,contact_email,contact_phone)
  values(p_tenant,p_request,trim(p_name),p_type,p_timezone,p_currency,
    coalesce(p_details->>'address',''),coalesce(p_details->>'city',''),coalesce(p_details->>'country_code','IN'),
    coalesce(p_details->>'contact_email',''),coalesce(p_details->>'contact_phone','')) returning id into v_id;
  return v_id;
end $$;
revoke all on function public.create_property(uuid,uuid,text,text,text,text,jsonb) from public,anon;
grant execute on function public.create_property(uuid,uuid,text,text,text,text,jsonb) to authenticated;
