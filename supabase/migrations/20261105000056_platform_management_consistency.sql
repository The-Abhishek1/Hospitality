-- Use an unambiguous reservation alias in the portal access gate.
create or replace function private.portal_reservation(p_token text) returns public.reservations
language plpgsql security definer set search_path = '' as $$
declare t public.guest_access_tokens; r public.reservations;
begin
  select * into t from public.guest_access_tokens where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'utf8')), 'hex');
  if not found or t.revoked_at is not null or t.expires_at < now() then
    raise exception 'invalid or expired link' using errcode = '28000';
  end if;
  if not exists(select 1 from public.reservations stay join public.tenants b on b.id=stay.tenant_id where stay.id=t.reservation_id and b.status='active')then raise exception 'Hotel access is currently unavailable.'using errcode='42501';end if;
  update public.guest_access_tokens set last_used_at = now(), use_count = use_count + 1 where id = t.id;
  select * into r from public.reservations where id = t.reservation_id;
  return r;
end $$;

-- An unsubscribed/canceled business must receive an eligible plan before platform hotel creation.
create or replace function public.platform_manage(p_tenant uuid,p_version integer,p_request uuid,p_action text,p_details jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$
declare actor uuid:=auth.uid();payload jsonb;saved private.platform_commands;t public.tenants;result jsonb;reason text;target_plan public.plans;old_sub jsonb;cap jsonb;hotel_id uuid;owner_id uuid;business_id uuid;hotel_count integer;
begin
 if not private.is_platform_admin()then raise exception 'Platform administrator access required.'using errcode='42501';end if;
 if p_request is null or p_action is null or p_action not in('plan','status','add_hotel','onboard')or p_details is null or jsonb_typeof(p_details)<>'object'then raise exception 'Invalid administration request.'using errcode='22023';end if;
 reason:=trim(coalesce(p_details->>'reason',''));if length(reason)not between 3 and 500 then raise exception 'Give a reason of 3–500 characters.'using errcode='22023';end if;
 payload:=jsonb_build_object('tenant',p_tenant,'version',p_version,'action',p_action,'details',p_details);
 perform pg_advisory_xact_lock(hashtextextended(actor::text||p_request::text,0));
 select * into saved from private.platform_commands where actor_id=actor and request_id=p_request;
 if found then if saved.payload<>payload then raise exception 'This request was already used for another change. Refresh the form.'using errcode='22023';end if;return saved.result;end if;
 if p_action='onboard'then
  if p_tenant is not null or p_version is not null then raise exception 'A new business must not specify an existing account.'using errcode='22023';end if;
  if length(trim(coalesce(p_details->>'business_name','')))not between 2 and 120 or coalesce(p_details->>'slug','')!~'^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$'then raise exception 'Enter a business name and a unique 3–50 character lowercase slug.'using errcode='22023';end if;
  select id into owner_id from auth.users where lower(email)=lower(trim(p_details->>'owner_email'))and email_confirmed_at is not null and deleted_at is null and(banned_until is null or banned_until<now());
  if owner_id is null then raise exception 'The owner must first sign up and confirm this email address.'using errcode='22023';end if;
  select * into target_plan from public.plans where key=p_details->>'plan'and active;
  if not found then raise exception 'Choose an active plan.'using errcode='22023';end if;
  insert into public.tenants(name,slug)values(trim(p_details->>'business_name'),p_details->>'slug')returning * into t;
  insert into public.tenant_memberships(tenant_id,user_id,role)values(t.id,owner_id,'owner');
  insert into public.subscriptions(tenant_id,plan_id,status)values(t.id,target_plan.id,'active');
 else
  select * into t from public.tenants where id=p_tenant for update;
  if not found then raise exception 'Business account not found.'using errcode='P0002';end if;
  if p_version is null or p_version<>t.admin_version then raise exception 'This account changed. Refresh and review before saving.'using errcode='40001';end if;
 end if;
 if p_action in('plan','status')and p_details->>'confirmation'is distinct from t.slug then raise exception 'Type the business slug to confirm which account is affected.'using errcode='22023';end if;
 if p_action='plan'then
  select * into target_plan from public.plans where key=p_details->>'plan'and active;
  if not found then raise exception 'Choose an active plan.'using errcode='22023';end if;
  select value into cap from public.plan_entitlements where plan_id=target_plan.id and key='max_properties';
  select count(*)into hotel_count from public.properties where tenant_id=t.id;
  if cap is not null and hotel_count>(cap#>>'{}')::integer then raise exception 'This business has % hotels; the selected plan permits %. Choose a plan that fits all existing hotels.',hotel_count,cap#>>'{}'using errcode='53400';end if;
  select to_jsonb(s)into old_sub from public.subscriptions s where tenant_id=t.id;
  if old_sub->>'plan_id'=target_plan.id::text and old_sub->>'status'='active'then raise exception 'This plan is already active.'using errcode='22023';end if;
  insert into public.subscriptions(tenant_id,plan_id,status)values(t.id,target_plan.id,'active')on conflict(tenant_id)do update set plan_id=excluded.plan_id,status='active',current_period_end=null;
 elsif p_action='status'then
  if p_details->>'status'is null or p_details->>'status'not in('active','suspended','closed')then raise exception 'Choose an account status.'using errcode='22023';end if;
  if p_details->>'status'=t.status then raise exception 'The account already has this status.'using errcode='22023';end if;
  update public.tenants set status=p_details->>'status'where id=t.id;
 end if;
 if p_action in('add_hotel','onboard')then
  if t.status<>'active'then raise exception 'Reactivate this business before adding hotels.'using errcode='22023';end if;
  if not exists(select 1 from public.subscriptions where tenant_id=t.id and status in('trialing','active','past_due'))then raise exception 'Assign an eligible subscription before adding hotels.'using errcode='22023';end if;
  if length(trim(coalesce(p_details->>'name','')))not between 2 and 120 or coalesce(p_details->>'property_type','')not in('hotel','resort','hostel','homestay')or coalesce(p_details->>'currency','')!~'^[A-Z]{3}$'or coalesce(p_details->>'country_code','')!~'^[A-Z]{2}$'or not exists(select 1 from pg_timezone_names where name=p_details->>'timezone')or length(coalesce(p_details->>'city',''))>120 then raise exception 'Check hotel name, type, city, country, timezone and currency.'using errcode='22023';end if;
  insert into public.properties(tenant_id,name,property_type,timezone,currency,city,country_code)values(t.id,trim(p_details->>'name'),p_details->>'property_type',p_details->>'timezone',p_details->>'currency',coalesce(p_details->>'city',''),p_details->>'country_code')returning id into hotel_id;
 end if;
 update public.tenants set admin_version=admin_version+1 where id=t.id returning admin_version into hotel_count;
 result:=jsonb_build_object('tenant_id',t.id,'property_id',hotel_id,'version',hotel_count);
 insert into public.platform_audit_logs(actor_id,action,tenant_id,details)values(actor,'platform_'||p_action,t.id,jsonb_build_object('reason',reason,'request_id',p_request,'before',case when p_action='status'then jsonb_build_object('status',t.status)when p_action='plan'then old_sub else null end,'after',case when p_action='status'then jsonb_build_object('status',p_details->>'status')when p_action='plan'then jsonb_build_object('plan',target_plan.key,'subscription_status','active')else jsonb_build_object('property_id',hotel_id,'hotel',p_details->>'name','owner_id',owner_id,'plan',case when p_action='onboard'then target_plan.key end)end));
 insert into private.platform_commands(actor_id,request_id,payload,result)values(actor,p_request,payload,result);return result;
end $$;
