create function private.team_roles(p_tenant uuid)returns jsonb language sql stable security definer set search_path=''as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'key',r.key,'name',r.name,'custom',r.tenant_id is not null,'assignable',(select count(*)from public.roles same where same.key=r.key and(same.tenant_id is null or same.tenant_id=p_tenant))=1,'permissions',coalesce((select jsonb_agg(jsonb_build_object('key',p.key,'description',p.description)order by p.key)from public.role_permissions rp join public.permissions p on p.key=rp.permission_key where rp.role_id=r.id),'[]'::jsonb))order by r.name,r.id),'[]'::jsonb)from public.roles r where r.tenant_id is null or r.tenant_id=p_tenant
$$;
revoke all on function private.team_roles(uuid)from public,anon,authenticated;

create function public.team_workspace(p_tenant uuid,p_filters jsonb default '{}')returns jsonb language plpgsql stable security definer set search_path=''as $$
declare result jsonb;business public.tenants;actor_role text;query text:=left(trim(coalesce(p_filters->>'q','')),100);mode text:=coalesce(p_filters->>'mode','members');state_filter text:=coalesce(p_filters->>'state','all');pg integer:=greatest(1,least(100000,coalesce((p_filters->>'page')::integer,1)));
begin
 if not private.is_tenant_admin(p_tenant)then raise exception 'not permitted'using errcode='42501';end if;
 select * into business from public.tenants where id=p_tenant;select role into actor_role from public.tenant_memberships where tenant_id=p_tenant and user_id=auth.uid();
 if mode='invitations'then
 with all_rows as materialized(select i.*,case when i.status='pending'and i.expires_at<=now()then 'expired'else i.status end as state,coalesce(pr.full_name,pr.email,'Staff')as inviter_name from public.staff_invitations i left join public.profiles pr on pr.id=i.invited_by where i.tenant_id=p_tenant),filtered as materialized(select * from all_rows i where(query=''or strpos(lower(i.email),lower(query))>0)and(state_filter='all'or i.state=state_filter)and(coalesce(p_filters->>'property','')=''or i.tenant_role='admin'or exists(select 1 from jsonb_array_elements(i.grants)g where g->>'property_id'=p_filters->>'property')))
 select jsonb_build_object('total',(select count(*)from filtered),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select * from filtered order by case state when 'pending'then 0 when 'expired'then 1 else 2 end,created_at desc,id limit 20 offset(pg-1)*20)x),'[]'::jsonb))into result;
 elsif mode='history'then
 with filtered as materialized(select e.*from public.staff_events e where tenant_id=p_tenant and(query=''or strpos(lower(concat_ws(' ',e.subject_label,e.actor_name,e.action)),lower(query))>0))select jsonb_build_object('total',(select count(*)from filtered),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select * from filtered order by created_at desc,id desc limit 20 offset(pg-1)*20)x),'[]'::jsonb))into result;
 else
 with rows as materialized(select m.user_id,m.role,m.version,m.created_at,pr.full_name,coalesce(u.email,pr.email)as email,
 (select count(*)from public.properties p where p.tenant_id=p_tenant and(m.role in('owner','admin')or exists(select 1 from public.property_memberships pm where pm.property_id=p.id and pm.user_id=m.user_id)))as property_count,
 (select count(*)from public.tasks where tenant_id=p_tenant and assignee_id=m.user_id and status in('open','in_progress'))as open_tasks,
 (select count(*)from public.conversations where tenant_id=p_tenant and assigned_to=m.user_id and status='open')as open_conversations
 from public.tenant_memberships m join public.profiles pr on pr.id=m.user_id left join auth.users u on u.id=m.user_id where m.tenant_id=p_tenant and(query=''or strpos(lower(concat_ws(' ',pr.full_name,u.email,pr.email,m.user_id::text)),lower(query))>0)
 and(coalesce(p_filters->>'role','')=''or m.role=p_filters->>'role')and(coalesce(p_filters->>'property','')=''or m.role in('owner','admin')or exists(select 1 from public.property_memberships pm where pm.user_id=m.user_id and pm.property_id::text=p_filters->>'property')))
 select jsonb_build_object('total',(select count(*)from rows),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select * from rows order by case role when 'owner'then 0 when 'admin'then 1 else 2 end,coalesce(full_name,email),user_id limit 20 offset(pg-1)*20)x),'[]'::jsonb))into result;
 end if;
 return result||jsonb_build_object('page',pg,'tenant_name',business.name,'actor_id',auth.uid(),'actor_role',actor_role,'properties',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'timezone',timezone)order by name,id)from public.properties where tenant_id=p_tenant),'[]'::jsonb),
 'stats',jsonb_build_object('members',(select count(*)from public.tenant_memberships where tenant_id=p_tenant),'owners',(select count(*)from public.tenant_memberships where tenant_id=p_tenant and role='owner'),'admins',(select count(*)from public.tenant_memberships where tenant_id=p_tenant and role='admin'),'pending',(select count(*)from public.staff_invitations where tenant_id=p_tenant and status='pending'and expires_at>now()),'expired',(select count(*)from public.staff_invitations where tenant_id=p_tenant and status='pending'and expires_at<=now())));
end $$;

create function public.team_setup(p_tenant uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
begin
 if not private.is_tenant_admin(p_tenant)then raise exception 'not permitted'using errcode='42501';end if;
 return jsonb_build_object('tenant_name',(select name from public.tenants where id=p_tenant),'actor_id',auth.uid(),'can_owner',private.is_tenant_owner(p_tenant),'roles',private.team_roles(p_tenant),'properties',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'timezone',timezone)order by name,id)from public.properties where tenant_id=p_tenant),'[]'::jsonb));
end $$;

create function public.team_member_detail(p_tenant uuid,p_user uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
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
 'open_tasks',(select count(*)from public.tasks where property_id=p.id and assignee_id=p_user and status in('open','in_progress')),'open_conversations',(select count(*)from public.conversations where property_id=p.id and assigned_to=p_user and status='open'))order by p.name,p.id)from public.properties p where p.tenant_id=p_tenant),'[]'::jsonb),
 'events',coalesce((select jsonb_agg(to_jsonb(x))from(select * from public.staff_events where tenant_id=p_tenant and target_user=p_user order by created_at desc,id desc limit 30)x),'[]'::jsonb));return result;
end $$;

create function public.team_invitation_detail(p_tenant uuid,p_id uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare i public.staff_invitations;
begin
 if not private.is_tenant_admin(p_tenant)then raise exception 'not permitted'using errcode='42501';end if;
 select * into i from public.staff_invitations where tenant_id=p_tenant and id=p_id;if not found then raise exception 'Invitation not found in this business.'using errcode='P0002';end if;
 return public.team_setup(p_tenant)||jsonb_build_object('invitation',to_jsonb(i)||jsonb_build_object('state',case when i.status='pending'and i.expires_at<=now()then 'expired'else i.status end),
 'can_manage',i.tenant_role<>'admin'or private.is_tenant_owner(p_tenant),'events',coalesce((select jsonb_agg(to_jsonb(x))from(select * from public.staff_events where tenant_id=p_tenant and invitation_id=p_id order by created_at desc,id desc limit 30)x),'[]'::jsonb));
end $$;
revoke all on function public.team_workspace(uuid,jsonb),public.team_setup(uuid),public.team_member_detail(uuid,uuid),public.team_invitation_detail(uuid,uuid)from public,anon;
grant execute on function public.team_workspace(uuid,jsonb),public.team_setup(uuid),public.team_member_detail(uuid,uuid),public.team_invitation_detail(uuid,uuid)to authenticated;
