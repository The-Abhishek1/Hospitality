-- Email delivery is separate from access. An email failure never removes an invitation.
create table public.staff_invitation_emails (
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references public.tenants(id) on delete cascade,
 invitation_id uuid not null references public.staff_invitations(id) on delete cascade,
 request_id uuid not null,
 invitation_version integer not null,
 requested_by uuid references public.profiles(id) on delete set null,
 status text not null default 'sending' check(status in('sending','sent','failed','unknown')),
 provider_id text,
 error_code text check(error_code in('configuration','authorization','sender','recipient','rate_limit','provider','uncertain')),
 context jsonb not null,
 created_at timestamptz not null default now(),
 finished_at timestamptz,
 unique(tenant_id,request_id)
);
create index staff_invitation_emails_latest on public.staff_invitation_emails(invitation_id,created_at desc,id desc);
create index staff_invitation_emails_rate on public.staff_invitation_emails(tenant_id,created_at desc);
alter table public.staff_invitation_emails enable row level security;
revoke all on public.staff_invitation_emails from public,anon,authenticated;
grant select on public.staff_invitation_emails to authenticated;
grant all on public.staff_invitation_emails to service_role;
create policy staff_invitation_emails_read on public.staff_invitation_emails for select to authenticated using(private.is_tenant_admin(tenant_id));

-- This view applies the base table's RLS and gives directories one row per invitation.
create view public.staff_invitation_email_latest with(security_invoker=true)as
 select distinct on(invitation_id) invitation_id,tenant_id,id,status,error_code,created_at,finished_at
 from public.staff_invitation_emails order by invitation_id,created_at desc,id desc;
revoke all on public.staff_invitation_email_latest from public,anon;
grant select on public.staff_invitation_email_latest to authenticated,service_role;

create function public.team_invitation_email_start(p_tenant uuid,p_invitation uuid,p_request uuid,p_version integer)returns jsonb
language plpgsql security definer set search_path=''as $$
declare i public.staff_invitations;e public.staff_invitation_emails;ctx jsonb;
begin
 perform private.staff_lock(p_tenant);
 if not private.is_tenant_admin(p_tenant)then raise exception 'not permitted'using errcode='42501';end if;
 select * into i from public.staff_invitations where id=p_invitation and tenant_id=p_tenant for update;
 if not found then raise exception 'Invitation not found in this business.'using errcode='P0002';end if;
 if i.tenant_role='admin'and not private.is_tenant_owner(p_tenant)then raise exception 'Only an owner can email administrator invitations.'using errcode='42501';end if;
 if p_request is null or p_version is null then raise exception 'Reload this invitation.'using errcode='22023';end if;
 if i.version<>p_version then raise exception 'This invitation changed. Refresh before sending.'using errcode='40001';end if;
 if i.status<>'pending'or i.expires_at<=now()then raise exception 'Only valid, pending invitations can be emailed. Renew an expired invitation first.'using errcode='22023';end if;
 -- The inviter must still be allowed to delegate these roles.
 if i.invited_by is not null and not exists(select 1 from public.tenant_memberships where tenant_id=p_tenant and user_id=i.invited_by and role in('owner','admin'))then raise exception 'The original inviter no longer has business administration access. Create a new reviewed invitation.'using errcode='22023';end if;
 perform private.staff_validate_grants(p_tenant,i.grants);
 select * into e from public.staff_invitation_emails where tenant_id=p_tenant and request_id=p_request;
 if found then
  if e.invitation_id<>i.id or e.invitation_version<>p_version then raise exception 'Email request already used for another invitation.'using errcode='22023';end if;
  return jsonb_build_object('send',false,'delivery_id',e.id,'status',e.status,'error_code',e.error_code);
 end if;
 if exists(select 1 from public.staff_invitation_emails where invitation_id=i.id and created_at>now()-interval '2 minutes')then raise exception 'Wait two minutes before sending this invitation again.'using errcode='22023';end if;
 if(select count(*)from public.staff_invitation_emails where invitation_id=i.id and created_at>now()-interval '1 day')>=10 then raise exception 'This invitation has reached its daily email limit. Try again tomorrow.'using errcode='22023';end if;
 if(select count(*)from public.staff_invitation_emails where tenant_id=p_tenant and created_at>now()-interval '1 hour')>=100 then raise exception 'This business has reached its hourly invitation email limit. Try again later.'using errcode='22023';end if;
 ctx:=jsonb_build_object('email',i.email,'business',(select name from public.tenants where id=p_tenant),'business_role',i.tenant_role,'expires_at',i.expires_at,
  'hotels',coalesce((select jsonb_agg(jsonb_build_object('name',p.name,'roles',(select jsonb_agg(r.name order by r.name)from jsonb_array_elements(i.grants)g join public.roles r on r.key=g->>'role_key'and(r.tenant_id is null or r.tenant_id=p_tenant)where g->>'property_id'=p.id::text))order by p.name,p.id)from public.properties p where p.tenant_id=p_tenant and exists(select 1 from jsonb_array_elements(i.grants)g where g->>'property_id'=p.id::text)),'[]'::jsonb));
 insert into public.staff_invitation_emails(tenant_id,invitation_id,request_id,invitation_version,requested_by,context)values(p_tenant,i.id,p_request,p_version,auth.uid(),ctx)returning * into e;
 perform private.staff_log(p_tenant,'invitation_email_requested',null,i.id,jsonb_build_object('delivery_id',e.id));
 return jsonb_build_object('send',true,'delivery_id',e.id,'status',e.status,'context',ctx);
end $$;
revoke all on function public.team_invitation_email_start(uuid,uuid,uuid,integer)from public,anon;
grant execute on function public.team_invitation_email_start(uuid,uuid,uuid,integer)to authenticated;

-- Only the backend records provider results. Clients cannot claim an email was sent.
create function public.team_invitation_email_finish(p_delivery uuid,p_status text,p_provider_id text default null,p_error text default null)returns void
language plpgsql security definer set search_path=''as $$
declare e public.staff_invitation_emails;
begin
 if p_status is null or p_status not in('sent','failed','unknown')or(p_status='sent'and(nullif(p_provider_id,'')is null or length(p_provider_id)>200))or(p_status<>'sent'and(p_error is null or p_error not in('configuration','authorization','sender','recipient','rate_limit','provider','uncertain')))then raise exception 'Invalid email result.'using errcode='22023';end if;
 select * into e from public.staff_invitation_emails where id=p_delivery;
 if not found then raise exception 'Email request not found.'using errcode='P0002';end if;
 perform private.staff_lock(e.tenant_id);
 select * into e from public.staff_invitation_emails where id=p_delivery for update;
 if e.status<>'sending'then return;end if;
 update public.staff_invitation_emails set status=p_status,provider_id=case when p_status='sent'then p_provider_id end,error_code=case when p_status<>'sent'then p_error end,finished_at=now()where id=e.id;
 perform private.staff_log(e.tenant_id,'invitation_email_'||p_status,null,e.invitation_id,jsonb_build_object('delivery_id',e.id,'error_code',p_error));
end $$;
revoke all on function public.team_invitation_email_finish(uuid,text,text,text)from public,anon,authenticated;
grant execute on function public.team_invitation_email_finish(uuid,text,text,text)to service_role;
