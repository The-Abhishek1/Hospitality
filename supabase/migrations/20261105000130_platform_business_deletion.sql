-- Business removal orchestrates the tested hotel cleanup, then removes the account.
-- Receipts/tombstones have no tenant FK; old upload URLs must stay invalid afterward.
create table private.business_deletions(
 id uuid primary key,tenant_id uuid not null unique,business_name text not null,
 actor_id uuid not null,reason text not null,state text not null default 'hotels'check(state in('hotels','complete')),
 hotel_ids uuid[] not null default '{}',scope jsonb not null,
 created_at timestamptz not null default now(),completed_at timestamptz
);
revoke all on private.business_deletions from public,anon,authenticated,service_role;

create function private.guard_business_deletion_write()returns trigger language plpgsql security definer set search_path=''as $$
begin
 perform 1 from public.tenants where id=new.tenant_id for share;
 if exists(select 1 from private.business_deletions where tenant_id=new.tenant_id)or(tg_op='UPDATE'and exists(select 1 from private.business_deletions where tenant_id=old.tenant_id))then
  raise exception 'This business is being permanently deleted. Resume cleanup in Platform admin.'using errcode='55000';
 end if;
 return new;
end $$;
-- Explicit business-owned write surfaces. Hotel records already have their own freeze.
create trigger business_deletion_write before insert or update on public.properties for each row execute function private.guard_business_deletion_write();
create trigger business_deletion_write before insert or update on public.guests for each row execute function private.guard_business_deletion_write();
create trigger business_deletion_write before insert or update on public.roles for each row execute function private.guard_business_deletion_write();
create trigger business_deletion_write before insert or update on public.tenant_memberships for each row execute function private.guard_business_deletion_write();
create trigger business_deletion_write before insert or update on public.staff_invitations for each row execute function private.guard_business_deletion_write();
create trigger business_deletion_write before insert or update on public.staff_commands for each row execute function private.guard_business_deletion_write();
create trigger business_deletion_write before insert or update on public.staff_events for each row execute function private.guard_business_deletion_write();
create trigger business_deletion_write before insert or update on public.staff_invitation_emails for each row execute function private.guard_business_deletion_write();
create trigger business_deletion_write before insert or update on public.subscriptions for each row execute function private.guard_business_deletion_write();
create trigger business_deletion_write before insert or update on private.workspace_onboarding_requests for each row execute function private.guard_business_deletion_write();
create function private.guard_business_deletion_identity()returns trigger language plpgsql security definer set search_path=''as $$
begin
 if exists(select 1 from private.business_deletions where tenant_id=new.id)then raise exception 'This business is being permanently deleted and cannot be edited or reopened.'using errcode='55000';end if;
 return new;
end $$;
create trigger business_deletion_identity before insert or update on public.tenants for each row execute function private.guard_business_deletion_identity();
-- Custom-role permissions have no tenant_id column. Prevent edits through that edge too.
create function private.guard_business_deletion_role_permission()returns trigger language plpgsql security definer set search_path=''as $$
declare tid uuid;rid uuid;begin
 if tg_op='DELETE'then rid:=old.role_id;else rid:=new.role_id;end if;
 select tenant_id into tid from public.roles where id=rid;
 perform 1 from public.tenants where id=tid for share;
 if exists(select 1 from private.business_deletions where tenant_id=tid)then raise exception 'This business is being permanently deleted.'using errcode='55000';end if;
 if tg_op='UPDATE'and old.role_id is distinct from new.role_id then
  select tenant_id into tid from public.roles where id=old.role_id;
  perform 1 from public.tenants where id=tid for share;
  if exists(select 1 from private.business_deletions where tenant_id=tid)then raise exception 'This business is being permanently deleted.'using errcode='55000';end if;
 end if;
 if tg_op='DELETE'then return old;end if;return new;
end $$;
create trigger business_deletion_write before insert or update or delete on public.role_permissions for each row execute function private.guard_business_deletion_role_permission();

-- During business deletion all invitations/access history are removed at finalization.
-- Standalone hotel deletion still edits shared grants exactly as before.
do $$declare source text;start_marker text:=' -- Shared business access history retains other hotels'' grants, without this hotel''s data.';
 end_marker text:=' -- Verify all directly hotel-owned tables, including private jobs/audits/caches, were removed.';
begin
 source:=pg_get_functiondef('public.platform_hotel_deletion_step(uuid,uuid)'::regprocedure);
 if position(start_marker in source)=0 or position(end_marker in source)=0 then raise exception 'Hotel deletion function changed. Review the business cleanup integration before applying.';end if;
 source:=replace(source,start_marker,E' if not exists(select 1 from private.business_deletions where tenant_id=j.tenant_id and state=''hotels'')then\n'||start_marker);
 source:=replace(source,end_marker,E' end if;\n'||end_marker);
 execute source;
end $$;

-- Include abandoned business document uploads and files for prior hotel receipts.
create function private.business_deletion_files(p_tenant uuid)returns table(bucket text,path text)
language sql stable security definer set search_path=''as $$
 select o.bucket_id,o.name from storage.objects o where
 (o.bucket_id='guest-documents'and split_part(o.name,'/',1)=p_tenant::text)
 or(o.bucket_id in('hotel-whatsapp-photos','food-menu-photos','whatsapp-inbox-photos')and split_part(o.name,'/',1)in(
  select id::text from public.properties where tenant_id=p_tenant union select property_id::text from private.hotel_deletions where tenant_id=p_tenant))
$$;
create function private.guard_business_deletion_upload()returns trigger language plpgsql security definer set search_path=''as $$
declare prefix text;tid uuid;begin
 if new.bucket_id='guest-documents'then
  prefix:=split_part(new.name,'/',1);
  if prefix~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'then tid:=prefix::uuid;end if;
 elsif new.bucket_id in('hotel-whatsapp-photos','food-menu-photos','whatsapp-inbox-photos')then
  prefix:=split_part(new.name,'/',1);
  select tenant_id into tid from(select tenant_id from public.properties where id::text=prefix union all select tenant_id from private.hotel_deletions where property_id::text=prefix)x limit 1;
 else return new;end if;
 perform 1 from public.tenants where id=tid for share;
 if exists(select 1 from private.business_deletions where tenant_id=tid)then raise exception 'This business no longer accepts uploads.'using errcode='55000';end if;
 return new;
end $$;
create trigger business_deletion_upload before insert or update of name,bucket_id on storage.objects for each row execute function private.guard_business_deletion_upload();

create function public.platform_business_deletion_preview(p_tenant uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare t public.tenants;j private.business_deletions;p record;h jsonb;hotels jsonb:='[]';counts jsonb:='{}';blockers jsonb:='[]';files bigint:=0;left_hotels integer:=0;
begin
 if not private.is_platform_admin()then raise exception 'Platform administrator access required.'using errcode='42501';end if;
 select *into j from private.business_deletions where tenant_id=p_tenant;
 if j.id is not null then
  select count(*)into left_hotels from private.hotel_deletions where property_id=any(j.hotel_ids)and state<>'complete';
  select count(*)into files from private.business_deletion_files(p_tenant);
  return j.scope||jsonb_build_object('id',p_tenant,'tenant',p_tenant,'name',j.business_name,'state',j.state,'job',j.id,'hotel_remaining',left_hotels,'files_remaining',files);
 end if;
 select *into t from public.tenants where id=p_tenant;
 if t.id is null then raise exception 'Business account not found.'using errcode='P0002';end if;
 for p in select id,name from public.properties where tenant_id=t.id order by name,id loop
  h:=public.platform_hotel_deletion_preview(p.id);
  hotels:=hotels||jsonb_build_object('id',p.id,'name',p.name,'state',h->>'state','files_remaining',h->'files_remaining');
  files:=files+coalesce((h->>'files_remaining')::bigint,0);
  select coalesce(jsonb_object_agg(key,total),'{}')into counts from(select key,sum(value::bigint)total from(select key,value from jsonb_each_text(counts)union all select key,value from jsonb_each_text(h->'counts'))x group by key)y;
  blockers:=blockers||coalesce((select jsonb_agg(to_jsonb(p.name||': '||value))from jsonb_array_elements_text(coalesce(h->'blockers','[]'))),'[]');
 end loop;
 if exists(select 1 from public.staff_invitation_emails where tenant_id=t.id and status='sending'and created_at>now()-interval '5 minutes')then blockers:=blockers||'"Wait for the invitation email currently being sent to finish."'::jsonb;end if;
 select count(*)into files from private.business_deletion_files(t.id);
 return jsonb_build_object('id',t.id,'tenant',t.id,'name',t.name,'version',t.admin_version,'state','review','counts',counts,
 'hotels',hotels,'hotel_total',jsonb_array_length(hotels),'hotel_remaining',jsonb_array_length(hotels),'files_remaining',files,'blockers',blockers,
 'members',(select count(*)from public.tenant_memberships where tenant_id=t.id),'guest_profiles',(select count(*)from public.guests where tenant_id=t.id),
 'invitations',(select count(*)from public.staff_invitations where tenant_id=t.id),'custom_roles',(select count(*)from public.roles where tenant_id=t.id),
 'subscription_records',(select count(*)from public.subscriptions where tenant_id=t.id));
end $$;
revoke all on function public.platform_business_deletion_preview(uuid)from public,anon;
grant execute on function public.platform_business_deletion_preview(uuid)to authenticated;

create function public.platform_business_deletion_begin(p_tenant uuid,p_actor uuid,p_request uuid,p_version integer,p_name text,p_reason text)returns uuid
language plpgsql security definer set search_path=''as $$
declare t public.tenants;j private.business_deletions;p public.properties;scope jsonb;hotel_ids uuid[]:='{}';begin
 if not exists(select 1 from public.platform_admins where user_id=p_actor)then raise exception 'Platform administrator access required.'using errcode='42501';end if;
 if p_request is null or length(trim(coalesce(p_reason,'')))not between 5 and 1000 then raise exception 'Give a reason of 5–1,000 characters.'using errcode='22023';end if;
 select *into t from public.tenants where id=p_tenant for update;
 select *into j from private.business_deletions where tenant_id=p_tenant;
 if j.id is not null then return j.id;end if;
 if t.id is null then raise exception 'Business account not found.'using errcode='P0002';end if;
 if p_name is distinct from t.name or p_version is distinct from t.admin_version then raise exception 'Business details changed, or its name does not match. Refresh and review again.'using errcode='40001';end if;
 perform set_config('request.jwt.claim.sub',p_actor::text,true);
 scope:=public.platform_business_deletion_preview(t.id);
 if jsonb_array_length(scope->'blockers')>0 then raise exception '%',scope->'blockers'->>0 using errcode='55000';end if;
 -- Tenant lock also serializes hotel creation/transfer; all hotel freezes commit together.
 for p in select *from public.properties where tenant_id=t.id order by id for update loop
  perform public.platform_hotel_deletion_begin(p.id,p_actor,gen_random_uuid(),p.version,p.name,p_reason);
  hotel_ids:=array_append(hotel_ids,p.id);
 end loop;
 update public.tenants set status='suspended',admin_version=admin_version+1 where id=t.id;
 insert into private.business_deletions(id,tenant_id,business_name,actor_id,reason,hotel_ids,scope)
 values(p_request,t.id,t.name,p_actor,trim(p_reason),hotel_ids,scope-'id'-'tenant'-'version'-'state'-'name'-'blockers');
 insert into public.platform_audit_logs(actor_id,tenant_id,action,details)values(p_actor,t.id,'platform_business_deletion_started',jsonb_build_object('business',t.name,'reason',trim(p_reason),'request_id',p_request));
 return p_request;
end $$;

create function public.platform_business_deletion_step(p_job uuid,p_actor uuid)returns jsonb
language plpgsql security definer set search_path=''as $$
declare j private.business_deletions;hotel private.hotel_deletions;result jsonb;remaining integer;r record;used boolean;file_count bigint;begin
 if not exists(select 1 from public.platform_admins where user_id=p_actor)then raise exception 'Platform administrator access required.'using errcode='42501';end if;
 select *into j from private.business_deletions where id=p_job for update;
 if j.id is null then raise exception 'Deletion request not found.'using errcode='P0002';end if;
 if j.state='complete'then return jsonb_build_object('state','complete','files',jsonb_build_array());end if;
 select *into hotel from private.hotel_deletions where property_id=any(j.hotel_ids)and state<>'complete'order by property_id limit 1;
 if hotel.id is not null then
  result:=public.platform_hotel_deletion_step(hotel.id,p_actor);
  if result->>'state'='files'then return result||jsonb_build_object('hotel',hotel.hotel_name);end if;
  select count(*)into remaining from private.hotel_deletions where property_id=any(j.hotel_ids)and state<>'complete';
  return jsonb_build_object('state','hotels','remaining',remaining,'total',cardinality(j.hotel_ids),'completed',cardinality(j.hotel_ids)-remaining,'files',jsonb_build_array());
 end if;
 select count(*)into file_count from private.business_deletion_files(j.tenant_id);
 if file_count>0 then return jsonb_build_object('state','files','hotel','business uploads','remaining',file_count,'files',(select jsonb_agg(to_jsonb(f))from(select *from private.business_deletion_files(j.tenant_id)order by bucket,path limit 100)f));end if;
 perform 1 from public.tenants where id=j.tenant_id for update;
 if exists(select 1 from public.properties where tenant_id=j.tenant_id)then raise exception 'Hotel cleanup is incomplete. Resume business deletion.'using errcode='55000';end if;
 -- No business row disappears until every hotel's Storage and database cleanup finished.
 set constraints all deferred;
 delete from public.platform_audit_logs where tenant_id=j.tenant_id;
 delete from private.platform_commands c where c.result->>'tenant_id'=j.tenant_id::text or c.payload->>'tenant'=j.tenant_id::text;
 delete from public.tenants where id=j.tenant_id;
 set constraints all immediate;
 -- A future business-owned table without a proper ownership edge fails closed here.
 for r in select c.oid::regclass tbl from pg_class c join pg_namespace n on n.oid=c.relnamespace join pg_attribute a on a.attrelid=c.oid and a.attname='tenant_id'and a.attnum>0 and not a.attisdropped
 where n.nspname in('public','private')and c.relkind='r'and c.oid not in('private.hotel_deletions'::regclass,'private.business_deletions'::regclass)loop
  execute format('select exists(select 1 from %s where tenant_id=$1)',r.tbl)into used using j.tenant_id;
  if used then raise exception 'Business cleanup is incomplete in %. No account records were deleted; retry or contact support.',r.tbl using errcode='55000';end if;
 end loop;
 update private.business_deletions set state='complete',completed_at=now(),hotel_ids='{}',scope=scope-'hotels'where id=j.id;
 insert into public.platform_audit_logs(actor_id,tenant_id,action,details)values(p_actor,null,'platform_business_deleted',jsonb_build_object('business_id',j.tenant_id,'business',j.business_name,'reason',j.reason,'request_id',j.id,'counts',j.scope->'counts','hotel_total',j.scope->'hotel_total'));
 return jsonb_build_object('state','complete','files',jsonb_build_array());
end $$;
revoke all on function private.guard_business_deletion_write(),private.guard_business_deletion_identity(),private.guard_business_deletion_role_permission(),private.business_deletion_files(uuid),private.guard_business_deletion_upload()from public,anon,authenticated,service_role;
revoke all on function public.platform_business_deletion_begin(uuid,uuid,uuid,integer,text,text),public.platform_business_deletion_step(uuid,uuid)from public,anon,authenticated;
grant execute on function public.platform_business_deletion_begin(uuid,uuid,uuid,integer,text,text),public.platform_business_deletion_step(uuid,uuid)to service_role;

-- Expose only deletion progress metadata in the existing platform business page.
do $$declare source text;needle text:='''page'',pg);return result;';begin
 source:=pg_get_functiondef('public.platform_business(uuid,integer)'::regprocedure);
 if position(needle in source)=0 then raise exception 'Business read model changed. Review deletion progress integration.';end if;
 source:=replace(source,needle,'''page'',pg);result:=result||jsonb_build_object(''deletion'',(select jsonb_build_object(''id'',id,''state'',state)from private.business_deletions where tenant_id=t.id and state=''hotels''));return result;');
 execute source;
end $$;
