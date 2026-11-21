-- Keep invitation history navigable after staff removal and record the hotel in access events.
create or replace function public.team_invitation_detail(p_tenant uuid,p_id uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare i public.staff_invitations;
begin
 if not private.is_tenant_admin(p_tenant)then raise exception 'not permitted'using errcode='42501';end if;
 select * into i from public.staff_invitations where tenant_id=p_tenant and id=p_id;if not found then raise exception 'Invitation not found in this business.'using errcode='P0002';end if;
 return public.team_setup(p_tenant)||jsonb_build_object('invitation',to_jsonb(i)||jsonb_build_object('state',case when i.status='pending'and i.expires_at<=now()then 'expired'else i.status end),
 'member_exists',exists(select 1 from public.tenant_memberships where tenant_id=p_tenant and user_id=i.accepted_by),
 'can_manage',i.tenant_role<>'admin'or private.is_tenant_owner(p_tenant),'events',coalesce((select jsonb_agg(to_jsonb(x))from(select * from public.staff_events where tenant_id=p_tenant and invitation_id=p_id order by created_at desc,id desc limit 30)x),'[]'::jsonb));
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
 perform private.staff_log(tenant,'property_access_changed',p_user,null,jsonb_build_object('property_id',p_property,'property_name',(select name from public.properties where id=p_property),'before',old_roles,'after',to_jsonb(coalesce(p_role_keys,'{}'))));
end $$;
