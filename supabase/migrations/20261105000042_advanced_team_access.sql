alter table public.tenant_memberships add column version integer not null default 1;
alter table public.staff_invitations add column version integer not null default 1;
create function private.staff_version()returns trigger language plpgsql set search_path=''as $$begin new.version:=old.version+1;return new;end $$;
revoke all on function private.staff_version()from public,anon,authenticated;
create trigger staff_member_version before update on public.tenant_memberships for each row execute function private.staff_version();
create trigger staff_invitation_version before update on public.staff_invitations for each row execute function private.staff_version();
create table public.staff_events(id uuid primary key default gen_random_uuid(),tenant_id uuid not null references public.tenants(id)on delete cascade,target_user uuid,invitation_id uuid,action text not null,actor_id uuid,actor_name text,subject_label text,details jsonb not null default '{}',created_at timestamptz not null default now());
create index on public.staff_events(tenant_id,created_at);
alter table public.staff_events enable row level security;
create policy staff_events_read on public.staff_events for select to authenticated using(private.is_tenant_admin(tenant_id));
create table public.staff_commands(id uuid primary key default gen_random_uuid(),tenant_id uuid not null references public.tenants(id)on delete cascade,request_id uuid not null,target_user uuid,invitation_id uuid,action text not null,payload jsonb not null,result_id uuid not null,created_at timestamptz not null default now(),unique(tenant_id,request_id));
alter table public.staff_commands enable row level security;
create policy staff_commands_read on public.staff_commands for select to authenticated using(private.is_tenant_admin(tenant_id));
-- Membership changes use guarded RPCs, including the existing public staff APIs.
drop policy tenant_memberships_write on public.tenant_memberships;
drop policy property_memberships_write on public.property_memberships;
drop policy user_roles_write on public.user_roles;

create function private.staff_lock(p_tenant uuid)returns void language sql volatile set search_path=''as $$select pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('staff-tenant:'||p_tenant::text,0))$$;
revoke all on function private.staff_lock(uuid)from public,anon,authenticated;
create function private.staff_log(p_tenant uuid,p_action text,p_user uuid,p_invitation uuid,p_details jsonb default '{}')returns void language plpgsql security definer set search_path=''as $$
declare actor text;subject text;reason text;
begin
 select coalesce(full_name,email,'Staff')into actor from public.profiles where id=auth.uid();
 if p_user is not null then select coalesce(pr.full_name,u.email,pr.email,p_user::text)into subject from public.profiles pr left join auth.users u on u.id=pr.id where pr.id=p_user;else select email into subject from public.staff_invitations where id=p_invitation;end if;
 reason:=nullif(trim(current_setting('app.staff_reason',true)),'');
 insert into public.staff_events(tenant_id,target_user,invitation_id,action,actor_id,actor_name,subject_label,details)values(p_tenant,p_user,p_invitation,p_action,auth.uid(),coalesce(actor,'System'),subject,p_details||case when reason is not null then jsonb_build_object('reason',left(reason,500))else '{}'::jsonb end);
end $$;
revoke all on function private.staff_log(uuid,text,uuid,uuid,jsonb)from public,anon,authenticated;

-- Owner changes serialize before checking the last remaining owner.
create or replace function private.protect_last_owner()returns trigger language plpgsql security definer set search_path=''as $$
begin
 if not exists(select 1 from public.tenants where id=old.tenant_id)then return case when tg_op='DELETE'then old else new end;end if;
 perform private.staff_lock(old.tenant_id);
 if old.role='owner'and(tg_op='DELETE'or new.role<>'owner')and not exists(select 1 from public.tenant_memberships where tenant_id=old.tenant_id and role='owner'and user_id<>old.user_id)then raise exception 'a tenant must keep at least one owner'using errcode='23514';end if;
 return case when tg_op='DELETE'then old else new end;
end $$;

create function private.staff_validate_grants(p_tenant uuid,p_grants jsonb)returns void language plpgsql security definer set search_path=''as $$
declare g jsonb;
begin
 if p_grants is null or jsonb_typeof(p_grants)<>'array'or jsonb_array_length(p_grants)>200 then raise exception 'Choose up to 200 property-role assignments.'using errcode='22023';end if;
 if(select count(distinct(concat(x->>'property_id',':',x->>'role_key')))from jsonb_array_elements(p_grants)x)<>jsonb_array_length(p_grants)then raise exception 'Each property role can be selected once.'using errcode='22023';end if;
 for g in select * from jsonb_array_elements(p_grants)loop
 if not exists(select 1 from public.properties where id=(g->>'property_id')::uuid and tenant_id=p_tenant)then raise exception 'Choose properties belonging to this business.'using errcode='22023';end if;
 if(select count(*)from public.roles where key=g->>'role_key'and(tenant_id is null or tenant_id=p_tenant))<>1 then raise exception 'Choose a unique, recognized role key for this business.'using errcode='22023';end if;end loop;
end $$;
revoke all on function private.staff_validate_grants(uuid,jsonb)from public,anon,authenticated;

create or replace function public.invite_staff(p_tenant uuid,p_email text,p_tenant_role text,p_grants jsonb default '[]')returns uuid language plpgsql security definer set search_path=''as $$
declare email_address text:=lower(trim(p_email));created_id uuid;
begin
 perform private.staff_lock(p_tenant);
 if not private.is_tenant_admin(p_tenant)then raise exception 'not permitted'using errcode='42501';end if;
 if p_tenant_role is null or p_tenant_role not in('admin','member')then raise exception 'role must be admin or member'using errcode='22023';end if;
 if p_tenant_role='admin'and not private.is_tenant_owner(p_tenant)then raise exception 'Only an owner can invite a business administrator.'using errcode='42501';end if;
 if email_address is null or length(email_address)>254 or email_address!~'^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'then raise exception 'Enter a valid staff email address.'using errcode='22023';end if;
 if exists(select 1 from public.tenant_memberships m join auth.users u on u.id=m.user_id where m.tenant_id=p_tenant and lower(u.email)=email_address)then raise exception 'This person already belongs to the business. Update their access from the team directory.'using errcode='22023';end if;
 perform private.staff_validate_grants(p_tenant,p_grants);
 if p_tenant_role='admin'and jsonb_array_length(p_grants)>0 then raise exception 'Administrator invitations have full access; clear property-specific grants.'using errcode='22023';end if;
 insert into public.staff_invitations(tenant_id,email,tenant_role,grants,invited_by)values(p_tenant,email_address,p_tenant_role,p_grants,auth.uid())returning id into created_id;
 perform private.staff_log(p_tenant,'invitation_created',null,created_id,jsonb_build_object('business_role',p_tenant_role,'grants',p_grants));return created_id;
end $$;

create or replace function public.revoke_staff_invitation(p_id uuid)returns void language plpgsql security definer set search_path=''as $$
declare i public.staff_invitations;
begin
 select * into i from public.staff_invitations where id=p_id;if not found then raise exception 'not permitted'using errcode='42501';end if;
 perform private.staff_lock(i.tenant_id);select * into i from public.staff_invitations where id=p_id for update;
 if not private.is_tenant_admin(i.tenant_id)then raise exception 'not permitted'using errcode='42501';end if;
 if i.tenant_role='admin'and not private.is_tenant_owner(i.tenant_id)then raise exception 'Only an owner can revoke an administrator invitation.'using errcode='42501';end if;
 if i.status<>'pending'then raise exception 'Only pending invitations can be revoked.'using errcode='22023';end if;
 update public.staff_invitations set status='revoked'where id=i.id;perform private.staff_log(i.tenant_id,'invitation_revoked',null,i.id);
end $$;

create or replace function public.set_staff_access(p_property uuid,p_user uuid,p_role_keys text[])returns void language plpgsql security definer set search_path=''as $$
declare tenant uuid;ids uuid[];target_role text;old_roles jsonb;grants jsonb;
begin
 select tenant_id into tenant from public.properties where id=p_property;if tenant is null then raise exception 'not permitted'using errcode='42501';end if;perform private.staff_lock(tenant);
 if not private.is_tenant_admin(tenant)then raise exception 'not permitted'using errcode='42501';end if;
 select role into target_role from public.tenant_memberships where tenant_id=tenant and user_id=p_user;
 if target_role is null then raise exception 'not a member of this tenant'using errcode='22023';end if;if target_role in('owner','admin')then raise exception 'owners and admins already have full access'using errcode='22023';end if;
 select coalesce(jsonb_agg(jsonb_build_object('property_id',p_property,'role_key',k)),'[]')into grants from unnest(coalesce(p_role_keys,'{}'))k;perform private.staff_validate_grants(tenant,grants);
 select coalesce(array_agg(id),'{}')into ids from public.roles where key=any(coalesce(p_role_keys,'{}'))and(tenant_id is null or tenant_id=tenant);
 if not exists(select 1 from public.role_permissions where role_id=any(ids)and permission_key='tasks.write')and exists(select 1 from public.tasks where property_id=p_property and assignee_id=p_user and status in('open','in_progress'))then raise exception 'Reassign or resolve this teammate’s open tasks before removing task-work access.'using errcode='22023';end if;
 if not exists(select 1 from public.role_permissions where role_id=any(ids)and permission_key='whatsapp.use')and exists(select 1 from public.conversations where property_id=p_property and assigned_to=p_user and status<>'closed')then raise exception 'Reassign or close this teammate’s inbox conversations before removing inbox access.'using errcode='22023';end if;
 select coalesce(jsonb_agg(r.key order by r.key),'[]')into old_roles from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.property_id=p_property and ur.user_id=p_user;
 if cardinality(ids)=0 then delete from public.property_memberships where property_id=p_property and user_id=p_user;
 else insert into public.property_memberships(property_id,tenant_id,user_id)values(p_property,tenant,p_user)on conflict do nothing;delete from public.user_roles where property_id=p_property and user_id=p_user and role_id<>all(ids);insert into public.user_roles(property_id,user_id,role_id)select p_property,p_user,unnest(ids)on conflict do nothing;end if;
 update public.tenant_memberships set role=role where tenant_id=tenant and user_id=p_user;
 perform private.staff_log(tenant,'property_access_changed',p_user,null,jsonb_build_object('property_id',p_property,'before',old_roles,'after',to_jsonb(coalesce(p_role_keys,'{}'))));
end $$;

create or replace function public.set_tenant_role(p_tenant uuid,p_user uuid,p_role text)returns void language plpgsql security definer set search_path=''as $$
declare target_role text;i record;
begin
 perform private.staff_lock(p_tenant);if not private.is_tenant_owner(p_tenant)then raise exception 'not permitted'using errcode='42501';end if;
 if p_role is null or p_role not in('owner','admin','member')then raise exception 'invalid role'using errcode='22023';end if;
 select role into target_role from public.tenant_memberships where tenant_id=p_tenant and user_id=p_user;if not found then raise exception 'not a member'using errcode='22023';end if;
 if p_role='member'then
 if exists(select 1 from public.tasks t join public.properties p on p.id=t.property_id where p.tenant_id=p_tenant and t.assignee_id=p_user and t.status in('open','in_progress')and not exists(select 1 from public.user_roles ur join public.role_permissions rp on rp.role_id=ur.role_id where ur.property_id=t.property_id and ur.user_id=p_user and rp.permission_key='tasks.write'))then raise exception 'Reassign open tasks or configure task-work roles before changing this business role.'using errcode='22023';end if;
 if exists(select 1 from public.conversations c join public.properties p on p.id=c.property_id where p.tenant_id=p_tenant and c.assigned_to=p_user and c.status<>'closed'and not exists(select 1 from public.user_roles ur join public.role_permissions rp on rp.role_id=ur.role_id where ur.property_id=c.property_id and ur.user_id=p_user and rp.permission_key='whatsapp.use'))then raise exception 'Reassign or close inbox conversations before removing full business access.'using errcode='22023';end if;end if;
 update public.tenant_memberships set role=p_role where tenant_id=p_tenant and user_id=p_user;
 if target_role in('owner','admin')and p_role='member'then
 for i in select id from public.staff_invitations where tenant_id=p_tenant and invited_by=p_user and status='pending'loop update public.staff_invitations set status='revoked'where id=i.id;perform private.staff_log(p_tenant,'invitation_revoked_on_demotion',null,i.id);end loop;end if;
 perform private.staff_log(p_tenant,'business_role_changed',p_user,null,jsonb_build_object('before',target_role,'after',p_role));
end $$;

create or replace function public.remove_staff(p_tenant uuid,p_user uuid)returns void language plpgsql security definer set search_path=''as $$
declare target_role text;target_email text;i record;
begin
 perform private.staff_lock(p_tenant);if not private.is_tenant_admin(p_tenant)then raise exception 'not permitted'using errcode='42501';end if;
 select role into target_role from public.tenant_memberships where tenant_id=p_tenant and user_id=p_user;if not found then raise exception 'not a member'using errcode='22023';end if;
 if target_role in('owner','admin')and not private.is_tenant_owner(p_tenant)then raise exception 'Only an owner can remove an owner or administrator.'using errcode='42501';end if;
 if exists(select 1 from public.tasks where tenant_id=p_tenant and assignee_id=p_user and status in('open','in_progress'))then raise exception 'Reassign or resolve this teammate’s open tasks before removing business access.'using errcode='22023';end if;
 if exists(select 1 from public.conversations where tenant_id=p_tenant and assigned_to=p_user and status<>'closed')then raise exception 'Reassign or close this teammate’s inbox conversations before removing business access.'using errcode='22023';end if;
 select lower(email)into target_email from auth.users where id=p_user;
 for i in select id from public.staff_invitations where tenant_id=p_tenant and status='pending'and(invited_by=p_user or email=target_email)loop update public.staff_invitations set status='revoked'where id=i.id;perform private.staff_log(p_tenant,'invitation_revoked_on_removal',null,i.id);end loop;
 perform private.staff_log(p_tenant,'member_removed',p_user,null,jsonb_build_object('business_role',target_role));delete from public.tenant_memberships where tenant_id=p_tenant and user_id=p_user;
end $$;

create or replace function public.accept_staff_invitations()returns integer language plpgsql security definer set search_path=''as $$
declare email_address text;confirmed_at timestamptz;business record;i public.staff_invitations;g record;accepted integer:=0;
begin
 if auth.uid()is null then raise exception 'not authenticated'using errcode='28000';end if;select lower(email),email_confirmed_at into email_address,confirmed_at from auth.users where id=auth.uid();if email_address is null or confirmed_at is null then return 0;end if;
 for business in select distinct tenant_id from public.staff_invitations where email=email_address and status='pending'and expires_at>now()order by tenant_id loop
 perform private.staff_lock(business.tenant_id);
 for i in select * from public.staff_invitations where tenant_id=business.tenant_id and email=email_address and status='pending'and expires_at>now()order by created_at,id for update loop
 -- A removed inviter or deleted property/role cannot leave a stale invitation granting access.
 if i.invited_by is not null and not exists(select 1 from public.tenant_memberships where tenant_id=i.tenant_id and user_id=i.invited_by and role in('owner','admin'))then update public.staff_invitations set status='revoked'where id=i.id;perform private.staff_log(i.tenant_id,'invitation_invalidated',null,i.id);continue;end if;
 begin perform private.staff_validate_grants(i.tenant_id,i.grants);exception when sqlstate '22023'or foreign_key_violation then update public.staff_invitations set status='revoked'where id=i.id;perform private.staff_log(i.tenant_id,'invitation_invalidated',null,i.id);continue;end;
 insert into public.tenant_memberships(tenant_id,user_id,role)values(i.tenant_id,auth.uid(),i.tenant_role)on conflict do nothing;
 for g in select(x->>'property_id')::uuid as property_id,x->>'role_key'as role_key from jsonb_array_elements(i.grants)x loop
 insert into public.property_memberships(property_id,tenant_id,user_id)values(g.property_id,i.tenant_id,auth.uid())on conflict do nothing;
 insert into public.user_roles(property_id,user_id,role_id)select g.property_id,auth.uid(),r.id from public.roles r where r.key=g.role_key and(r.tenant_id is null or r.tenant_id=i.tenant_id)on conflict do nothing;end loop;
 update public.tenant_memberships set role=role where tenant_id=i.tenant_id and user_id=auth.uid();update public.staff_invitations set status='accepted',accepted_by=auth.uid(),accepted_at=now()where id=i.id;
 perform private.staff_log(i.tenant_id,'invitation_accepted',auth.uid(),i.id,jsonb_build_object('business_role',i.tenant_role));accepted:=accepted+1;
 end loop;end loop;return accepted;
end $$;

create function public.team_action(p_tenant uuid,p_request uuid,p_action text,p_target uuid,p_version integer,p_details jsonb default '{}')returns uuid language plpgsql security definer set search_path=''as $$
declare cmd public.staff_commands;i public.staff_invitations;m public.tenant_memberships;result_id uuid;ttl integer;property_id uuid;keys text[];
begin
 perform private.staff_lock(p_tenant);if not private.is_tenant_admin(p_tenant)then raise exception 'not permitted'using errcode='42501';end if;
 if p_request is null or p_details is null or jsonb_typeof(p_details)<>'object'then raise exception 'Reload this team form.'using errcode='22023';end if;
 select * into cmd from public.staff_commands where tenant_id=p_tenant and request_id=p_request;
 if found then if cmd.action<>p_action or coalesce(cmd.target_user,cmd.invitation_id)is distinct from p_target or cmd.payload is distinct from p_details then raise exception 'Request ID already used for different staff details.'using errcode='22023';end if;return cmd.result_id;end if;
 if p_action='invite'then
 ttl:=coalesce((p_details->>'days')::integer,14);if ttl not between 1 and 30 then raise exception 'Invitation validity must be 1–30 days.'using errcode='22023';end if;
 perform set_config('app.staff_reason','',true);
 -- Expired pending invitations may be replaced explicitly by a new reviewed invitation.
 for i in select * from public.staff_invitations where tenant_id=p_tenant and email=lower(trim(p_details->>'email'))and status='pending'and expires_at<=now()for update loop
 update public.staff_invitations set status='revoked'where id=i.id;perform private.staff_log(p_tenant,'expired_invitation_replaced',null,i.id);end loop;
 result_id:=public.invite_staff(p_tenant,p_details->>'email',p_details->>'business_role',coalesce(p_details->'grants','[]'));update public.staff_invitations set expires_at=now()+make_interval(days=>ttl)where id=result_id;
 elsif p_action in('renew','revoke')then
 select * into i from public.staff_invitations where tenant_id=p_tenant and id=p_target for update;if not found then raise exception 'Invitation not found in this business.'using errcode='22023';end if;
 if i.version is distinct from p_version then raise exception 'This invitation changed. Refresh before continuing.'using errcode='40001';end if;
 if i.status<>'pending'then raise exception 'Only pending invitations can be renewed or revoked.'using errcode='22023';end if;
 if i.tenant_role='admin'and not private.is_tenant_owner(p_tenant)then raise exception 'Only an owner can manage administrator invitations.'using errcode='42501';end if;
 if p_action='revoke'then perform public.revoke_staff_invitation(i.id);
 else ttl:=coalesce((p_details->>'days')::integer,14);if ttl not between 1 and 30 then raise exception 'Invitation validity must be 1–30 days.'using errcode='22023';end if;perform private.staff_validate_grants(p_tenant,i.grants);update public.staff_invitations set expires_at=now()+make_interval(days=>ttl),invited_by=auth.uid()where id=i.id;perform private.staff_log(p_tenant,'invitation_renewed',null,i.id,jsonb_build_object('days',ttl));end if;result_id:=i.id;
 elsif p_action in('access','role','remove')then
 select * into m from public.tenant_memberships where tenant_id=p_tenant and user_id=p_target;
 if not found then raise exception 'Team member not found in this business.'using errcode='22023';end if;if m.version is distinct from p_version then raise exception 'This member’s access changed. Refresh and review it before continuing.'using errcode='40001';end if;
 if length(trim(coalesce(p_details->>'reason','')))not between 3 and 500 then raise exception 'Give an access-change reason of 3–500 characters.'using errcode='22023';end if;
 perform set_config('app.staff_reason',trim(p_details->>'reason'),true);
 if p_action='access'then property_id:=(p_details->>'property_id')::uuid;if not exists(select 1 from public.properties where id=property_id and tenant_id=p_tenant)then raise exception 'Choose a property in this business.'using errcode='22023';end if;
 if jsonb_typeof(p_details->'roles')is distinct from 'array'then raise exception 'Choose a list of property roles.'using errcode='22023';end if;select coalesce(array_agg(k),'{}')into keys from jsonb_array_elements_text(p_details->'roles')k;perform public.set_staff_access(property_id,p_target,keys);
 elsif p_action='role'then perform public.set_tenant_role(p_tenant,p_target,p_details->>'business_role');else perform public.remove_staff(p_tenant,p_target);end if;perform set_config('app.staff_reason','',true);result_id:=p_target;
 else raise exception 'Choose a valid team action.'using errcode='22023';end if;
 insert into public.staff_commands(tenant_id,request_id,target_user,invitation_id,action,payload,result_id)values(p_tenant,p_request,case when p_action in('access','role','remove')then p_target end,case when p_action in('renew','revoke')then p_target end,p_action,p_details,result_id);return result_id;
end $$;
revoke all on function public.team_action(uuid,uuid,text,uuid,integer,jsonb)from public,anon;
grant execute on function public.team_action(uuid,uuid,text,uuid,integer,jsonb)to authenticated;
