-- Protect administrator invitations and keep role removal consistent with service routing.
create or replace function public.team_action(p_tenant uuid,p_request uuid,p_action text,p_target uuid,p_version integer,p_details jsonb default '{}')returns uuid language plpgsql security definer set search_path=''as $$
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
 if i.tenant_role='admin'and not private.is_tenant_owner(p_tenant)then raise exception 'Only an owner can replace an expired administrator invitation.'using errcode='42501';end if;update public.staff_invitations set status='revoked'where id=i.id;perform private.staff_log(p_tenant,'expired_invitation_replaced',null,i.id);end loop;
 result_id:=public.invite_staff(p_tenant,p_details->>'email',p_details->>'business_role',coalesce(p_details->'grants','[]'));update public.staff_invitations set expires_at=now()+make_interval(days=>ttl)where id=result_id;
 elsif p_action in('renew','revoke')then
 select * into i from public.staff_invitations where tenant_id=p_tenant and id=p_target for update;if not found then raise exception 'Invitation not found in this business.'using errcode='22023';end if;
 if i.version is distinct from p_version then raise exception 'This invitation changed. Refresh before continuing.'using errcode='40001';end if;
 if i.status<>'pending'then raise exception 'Only pending invitations can be renewed or revoked.'using errcode='22023';end if;
 if i.tenant_role='admin'and not private.is_tenant_owner(p_tenant)then raise exception 'Only an owner can manage administrator invitations.'using errcode='42501';end if;
 if p_action='revoke'then if length(trim(coalesce(p_details->>'reason','')))not between 3 and 500 then raise exception 'Give a revocation reason of 3–500 characters.'using errcode='22023';end if;perform set_config('app.staff_reason',trim(p_details->>'reason'),true);perform public.revoke_staff_invitation(i.id);perform set_config('app.staff_reason','',true);
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
 if not exists(select 1 from public.role_permissions where role_id=any(ids)and permission_key='tasks.write')and exists(select 1 from public.service_routing_rules where property_id=p_property and default_assignee_id=p_user)then raise exception 'Update this teammate’s default service routing before removing task-work access.'using errcode='22023';end if;
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
 if p_role='member'and exists(select 1 from public.service_routing_rules sr where sr.tenant_id=p_tenant and sr.default_assignee_id=p_user and not exists(select 1 from public.user_roles ur join public.role_permissions rp on rp.role_id=ur.role_id where ur.property_id=sr.property_id and ur.user_id=p_user and rp.permission_key='tasks.write'))then raise exception 'Update default service routing before removing full business access.'using errcode='22023';end if;
 update public.tenant_memberships set role=p_role where tenant_id=p_tenant and user_id=p_user;
 if target_role in('owner','admin')and p_role='member'then
 for i in select id from public.staff_invitations where tenant_id=p_tenant and invited_by=p_user and status='pending'loop update public.staff_invitations set status='revoked'where id=i.id;perform private.staff_log(p_tenant,'invitation_revoked_on_demotion',null,i.id);end loop;end if;
 perform private.staff_log(p_tenant,'business_role_changed',p_user,null,jsonb_build_object('before',target_role,'after',p_role));
end $$;

create or replace function public.team_member_detail(p_tenant uuid,p_user uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare m public.tenant_memberships;result jsonb;actor_role text;
begin
 if not private.is_tenant_admin(p_tenant)then raise exception 'not permitted'using errcode='42501';end if;
 select * into m from public.tenant_memberships where tenant_id=p_tenant and user_id=p_user;if not found then raise exception 'Member not found in this business.'using errcode='P0002';end if;
 select role into actor_role from public.tenant_memberships where tenant_id=p_tenant and user_id=auth.uid();
 result:=public.team_setup(p_tenant)||jsonb_build_object('member',jsonb_build_object('id',p_user,'version',m.version,'role',m.role,'created_at',m.created_at,'name',(select full_name from public.profiles where id=p_user),'email',(select coalesce(u.email,pr.email)from public.profiles pr left join auth.users u on u.id=pr.id where pr.id=p_user)),
 'can_edit_access',m.role='member','can_remove',actor_role='owner'or m.role='member',
 'access',coalesce((select jsonb_agg(jsonb_build_object('property_id',p.id,'property_name',p.name,'timezone',p.timezone,'has_access',m.role in('owner','admin')or exists(select 1 from public.property_memberships where property_id=p.id and user_id=p_user),
 'roles',coalesce((select jsonb_agg(r.key order by r.key)from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.property_id=p.id and ur.user_id=p_user),'[]'::jsonb),
 'permissions',case when m.role in('owner','admin')then(select jsonb_agg(key order by key)from public.permissions)else coalesce((select jsonb_agg(key order by key)from(select distinct rp.permission_key as key from public.user_roles ur join public.role_permissions rp on rp.role_id=ur.role_id where ur.property_id=p.id and ur.user_id=p_user)x),'[]'::jsonb)end,
 'default_services',(select count(*)from public.service_routing_rules where property_id=p.id and default_assignee_id=p_user),
 'tasks',coalesce((select jsonb_agg(to_jsonb(x))from(select id,title from public.tasks where property_id=p.id and assignee_id=p_user and status in('open','in_progress')order by created_at,id limit 5)x),'[]'::jsonb),
 'conversations',coalesce((select jsonb_agg(to_jsonb(x))from(select id,coalesce(contact_name,'Guest conversation')as name from public.conversations where property_id=p.id and assigned_to=p_user and status='open'order by last_message_at desc,id limit 5)x),'[]'::jsonb),
 'open_tasks',(select count(*)from public.tasks where property_id=p.id and assignee_id=p_user and status in('open','in_progress')),'open_conversations',(select count(*)from public.conversations where property_id=p.id and assigned_to=p_user and status='open'))order by p.name,p.id)from public.properties p where p.tenant_id=p_tenant),'[]'::jsonb),
 'events',coalesce((select jsonb_agg(to_jsonb(x))from(select * from public.staff_events where tenant_id=p_tenant and target_user=p_user order by created_at desc,id desc limit 30)x),'[]'::jsonb));return result;
end $$;
