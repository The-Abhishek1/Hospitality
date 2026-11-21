-- Platform metadata is exposed through scoped RPCs, never blanket operational RLS.
alter table public.tenants add column admin_version integer not null default 1;
create table private.platform_commands(
 actor_id uuid not null,request_id uuid not null,payload jsonb not null,result jsonb not null,
 created_at timestamptz not null default now(),primary key(actor_id,request_id)
);
revoke all on private.platform_commands from public,anon,authenticated;

create function public.platform_directory(p_query text default '',p_status text default 'all',p_page integer default 1)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare result jsonb;q text:=lower(left(trim(coalesce(p_query,'')),100));pg integer:=greatest(1,least(coalesce(p_page,1),100000));
begin
 if not private.is_platform_admin()then raise exception 'Platform administrator access required.'using errcode='42501';end if;
 if p_status is null or p_status not in('all','active','suspended','closed')then raise exception 'Invalid account status filter.'using errcode='22023';end if;
 with businesses as materialized(
 select t.id,t.name,t.slug,t.status,t.admin_version,t.created_at,s.status as subscription_status,s.current_period_end,p.key as plan_key,p.name as plan_name,
 (select count(*)from public.properties where tenant_id=t.id)as hotels,
 (select count(*)from public.tenant_memberships where tenant_id=t.id and role='owner')as owners
 from public.tenants t left join public.subscriptions s on s.tenant_id=t.id left join public.plans p on p.id=s.plan_id
 where(p_status='all'or t.status=p_status)and(q=''or strpos(lower(t.name||' '||t.slug||' '||t.id::text),q)>0 or exists(select 1 from public.properties h where h.tenant_id=t.id and strpos(lower(h.name||' '||h.city||' '||h.id::text),q)>0))
 ),hotels as materialized(
 select h.id,h.name,h.property_type,h.city,h.country_code,h.timezone,h.currency,h.created_at,h.tenant_id,t.name as business_name,t.slug,t.status,p.name as plan_name
 from public.properties h join public.tenants t on t.id=h.tenant_id left join public.subscriptions s on s.tenant_id=t.id left join public.plans p on p.id=s.plan_id
 where(p_status='all'or t.status=p_status)and(q=''or strpos(lower(concat_ws(' ',h.name,h.city,h.id::text,t.name,t.slug,t.id::text)),q)>0)
 )select jsonb_build_object('business_total',(select count(*)from businesses),'hotel_total',(select count(*)from hotels),'page',pg,
 'businesses',coalesce((select jsonb_agg(to_jsonb(x))from(select * from businesses order by created_at desc,id limit 20 offset(pg-1)*20)x),'[]'::jsonb),
 'hotels',coalesce((select jsonb_agg(to_jsonb(x))from(select * from hotels order by created_at desc,id limit 20 offset(pg-1)*20)x),'[]'::jsonb),
 'summary',jsonb_build_object('businesses',(select count(*)from public.tenants),'hotels',(select count(*)from public.properties),'suspended',(select count(*)from public.tenants where status='suspended'),'unsubscribed',(select count(*)from public.tenants t where not exists(select 1 from public.subscriptions where tenant_id=t.id))),
 'generated_at',now())into result;return result;
end $$;
revoke all on function public.platform_directory(text,text,integer)from public,anon;
grant execute on function public.platform_directory(text,text,integer)to authenticated;

create function public.platform_business(p_tenant uuid,p_page integer default 1)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare t public.tenants;result jsonb;pg integer:=greatest(1,least(coalesce(p_page,1),100000));
begin
 if not private.is_platform_admin()then raise exception 'Platform administrator access required.'using errcode='42501';end if;
 select * into t from public.tenants where id=p_tenant;if not found then raise exception 'Business account not found.'using errcode='P0002';end if;
 result:=jsonb_build_object('business',to_jsonb(t),
 'subscription',(select jsonb_build_object('status',s.status,'current_period_end',s.current_period_end,'plan_key',p.key,'plan_name',p.name,'price_monthly',p.price_monthly::text,'currency',p.currency,'entitlements',coalesce((select jsonb_object_agg(key,value)from public.plan_entitlements where plan_id=p.id),'{}'::jsonb))from public.subscriptions s join public.plans p on p.id=s.plan_id where s.tenant_id=t.id),
 'owners',coalesce((select jsonb_agg(jsonb_build_object('name',p.full_name,'email',u.email,'confirmed',u.email_confirmed_at is not null)order by m.created_at)from public.tenant_memberships m join public.profiles p on p.id=m.user_id join auth.users u on u.id=m.user_id where m.tenant_id=t.id and m.role='owner'),'[]'::jsonb),
 'member_count',(select count(*)from public.tenant_memberships where tenant_id=t.id),
 'hotel_total',(select count(*)from public.properties where tenant_id=t.id),
 'hotels',coalesce((select jsonb_agg(to_jsonb(x))from(select h.id,h.name,h.property_type,h.city,h.country_code,h.contact_email,h.contact_phone,h.timezone,h.currency,h.created_at,
 (select count(*)from public.accommodation_units where property_id=h.id and active)as active_rooms,
 (select count(*)from public.accommodation_types where property_id=h.id)as room_types,
 (select count(*)from public.property_memberships where property_id=h.id)as assigned_staff
 from public.properties h where h.tenant_id=t.id order by h.created_at desc,h.id limit 20 offset(pg-1)*20)x),'[]'::jsonb),
 'audit_total',(select count(*)from public.platform_audit_logs where tenant_id=t.id),
 'audit',coalesce((select jsonb_agg(to_jsonb(x))from(select a.id,a.action,a.details,a.created_at,coalesce(p.full_name,'Platform administrator')as actor from public.platform_audit_logs a left join public.profiles p on p.id=a.actor_id where a.tenant_id=t.id order by a.created_at desc,a.id desc limit 20 offset(pg-1)*20)x),'[]'::jsonb),
 'page',pg);return result;
end $$;
revoke all on function public.platform_business(uuid,integer)from public,anon;
grant execute on function public.platform_business(uuid,integer)to authenticated;

create function public.platform_manage(p_tenant uuid,p_version integer,p_request uuid,p_action text,p_details jsonb)returns jsonb
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
  if length(trim(coalesce(p_details->>'name','')))not between 2 and 120 or coalesce(p_details->>'property_type','')not in('hotel','resort','hostel','homestay')or coalesce(p_details->>'currency','')!~'^[A-Z]{3}$'or coalesce(p_details->>'country_code','')!~'^[A-Z]{2}$'or not exists(select 1 from pg_timezone_names where name=p_details->>'timezone')or length(coalesce(p_details->>'city',''))>120 then raise exception 'Check hotel name, type, city, country, timezone and currency.'using errcode='22023';end if;
  insert into public.properties(tenant_id,name,property_type,timezone,currency,city,country_code)values(t.id,trim(p_details->>'name'),p_details->>'property_type',p_details->>'timezone',p_details->>'currency',coalesce(p_details->>'city',''),p_details->>'country_code')returning id into hotel_id;
 end if;
 update public.tenants set admin_version=admin_version+1 where id=t.id returning admin_version into hotel_count;
 result:=jsonb_build_object('tenant_id',t.id,'property_id',hotel_id,'version',hotel_count);
 insert into public.platform_audit_logs(actor_id,action,tenant_id,details)values(actor,'platform_'||p_action,t.id,jsonb_build_object('reason',reason,'request_id',p_request,'before',case when p_action='status'then jsonb_build_object('status',t.status)when p_action='plan'then old_sub else null end,'after',case when p_action='status'then jsonb_build_object('status',p_details->>'status')when p_action='plan'then jsonb_build_object('plan',target_plan.key,'subscription_status','active')else jsonb_build_object('property_id',hotel_id,'hotel',p_details->>'name','owner_id',owner_id,'plan',case when p_action='onboard'then target_plan.key end)end));
 insert into private.platform_commands(actor_id,request_id,payload,result)values(actor,p_request,payload,result);return result;
end $$;
revoke all on function public.platform_manage(uuid,integer,uuid,text,jsonb)from public,anon;
grant execute on function public.platform_manage(uuid,integer,uuid,text,jsonb)to authenticated;

-- Keep existing API entry points guarded by the same validation and lock order.
create or replace function public.admin_assign_plan(p_tenant uuid,p_plan_key text)returns void language plpgsql security definer set search_path=''as $$
declare t public.tenants;
begin
 if not private.is_platform_admin()then raise exception 'platform admin only'using errcode='42501';end if;
 select * into t from public.tenants where id=p_tenant for update;
 perform public.platform_manage(p_tenant,t.admin_version,gen_random_uuid(),'plan',jsonb_build_object('plan',p_plan_key,'confirmation',t.slug,'reason','Plan assignment through legacy administration API.'));
end $$;
create or replace function public.admin_set_tenant_status(p_tenant uuid,p_status text,p_reason text)returns void language plpgsql security definer set search_path=''as $$
declare t public.tenants;
begin
 if not private.is_platform_admin()then raise exception 'platform admin only'using errcode='42501';end if;
 select * into t from public.tenants where id=p_tenant for update;
 perform public.platform_manage(p_tenant,t.admin_version,gen_random_uuid(),'status',jsonb_build_object('status',p_status,'confirmation',t.slug,'reason',p_reason));
end $$;
