-- First business and hotel are created together, with safe retries after a lost response.
create table private.workspace_onboarding_requests(
 actor uuid not null references public.profiles(id),request_id uuid not null,payload jsonb not null,
 tenant_id uuid not null references public.tenants(id)on delete cascade,property_id uuid not null references public.properties(id)on delete cascade,
 created_at timestamptz not null default now(),primary key(actor,request_id)
);
revoke all on private.workspace_onboarding_requests from public,anon,authenticated,service_role;
create function public.create_hotel_workspace(p_request uuid,p_business text,p_property text,p_type text,p_timezone text default 'Asia/Kolkata',p_currency text default 'INR')returns jsonb
language plpgsql security definer set search_path=''as $$
declare v_actor uuid:=auth.uid();payload jsonb;prior private.workspace_onboarding_requests;tenant uuid;hotel uuid;slug text;
begin
 if v_actor is null then raise exception 'Sign in before creating your hotel.'using errcode='42501';end if;
 if p_request is null or length(trim(coalesce(p_business,'')))not between 2 and 120 or length(trim(coalesce(p_property,'')))not between 2 and 120 or p_type is null or p_type not in('hotel','resort','hostel','homestay')or not exists(select 1 from pg_catalog.pg_timezone_names where name=p_timezone)or p_currency is null or p_currency!~'^[A-Z]{3}$'then raise exception 'Check the business, hotel, timezone and currency.'using errcode='22023';end if;
 payload:=jsonb_build_object('business',trim(p_business),'property',trim(p_property),'type',p_type,'timezone',p_timezone,'currency',p_currency);
 perform pg_advisory_xact_lock(hashtextextended('workspace-onboarding:'||v_actor,0));
 select *into prior from private.workspace_onboarding_requests r where r.actor=v_actor and r.request_id=p_request;
 if found then
  if prior.payload<>payload then raise exception 'This setup request was already used. Refresh before changing hotel details.'using errcode='22023';end if;
  return jsonb_build_object('tenant_id',prior.tenant_id,'property_id',prior.property_id);
 end if;
 slug:='hotel-'||replace(gen_random_uuid()::text,'-','');
 tenant:=public.create_tenant(trim(p_business),slug);
 insert into public.properties(tenant_id,name,property_type,timezone,currency)values(tenant,trim(p_property),p_type,p_timezone,p_currency)returning id into hotel;
 insert into private.workspace_onboarding_requests(actor,request_id,payload,tenant_id,property_id)values(v_actor,p_request,payload,tenant,hotel);
 return jsonb_build_object('tenant_id',tenant,'property_id',hotel);
end $$;
revoke all on function public.create_hotel_workspace(uuid,text,text,text,text,text)from public,anon;
grant execute on function public.create_hotel_workspace(uuid,text,text,text,text,text)to authenticated;
