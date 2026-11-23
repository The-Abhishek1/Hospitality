-- Closing a hotel preserves its records; it never cascades a property deletion.
alter table public.properties add column archived_at timestamptz,add column archived_by uuid references public.profiles(id),add column closure_reason text not null default '';
create table private.property_lifecycle_events(id uuid primary key default gen_random_uuid(),property_id uuid not null references public.properties(id),action text not null,reason text not null,actor uuid not null references public.profiles(id),created_at timestamptz not null default clock_timestamp());
revoke all on private.property_lifecycle_events from public,anon,authenticated,service_role;
-- State transitions go through the reviewed, version-checked owner command.
revoke update on public.properties from authenticated;
grant update(tenant_id,name,property_type,timezone,currency,address,city,country_code,contact_email,contact_phone,creation_request_id)on public.properties to authenticated;
drop policy properties_delete on public.properties;
create policy properties_delete on public.properties for delete to authenticated using(false);

create or replace function private.has_property_access(p uuid)returns boolean language sql stable security definer set search_path=''as $$
 select exists(select 1 from public.properties pr where pr.id=p and private.tenant_is_active(pr.tenant_id)and(private.is_tenant_admin(pr.tenant_id)or pr.archived_at is null and exists(select 1 from public.property_memberships pm where pm.property_id=p and pm.user_id=auth.uid())))
$$;
create or replace function private.has_permission(p uuid,perm text)returns boolean language sql stable security definer set search_path=''as $$
 select exists(select 1 from public.properties pr where pr.id=p and private.tenant_is_active(pr.tenant_id)
 and(pr.archived_at is null or private.is_tenant_admin(pr.tenant_id)and right(perm,5)='.read')
 and(private.is_tenant_admin(pr.tenant_id)or exists(select 1 from public.user_roles ur join public.role_permissions rp on rp.role_id=ur.role_id where ur.property_id=p and ur.user_id=auth.uid()and rp.permission_key=perm)))
$$;
create or replace function private.enforce_property_limit()returns trigger language plpgsql security definer set search_path=''as $$
declare v jsonb;
begin
 perform 1 from public.tenants where id=new.tenant_id for update;
 if tg_op='UPDATE'and(old.archived_at is null or new.archived_at is not null)then return new;end if;
 if new.archived_at is not null then return new;end if;
 v:=private.entitlement(new.tenant_id,'max_properties');
 if v is not null and(select count(*)from public.properties where tenant_id=new.tenant_id and archived_at is null and id<>new.id)>=(v#>>'{}')::int then raise exception 'property limit reached for current plan'using errcode='53400';end if;
 return new;
end $$;
create trigger properties_reopen_limit before update of archived_at on public.properties for each row execute function private.enforce_property_limit();

-- Writes from staff RPCs and background booking ingestion both respect closure.
create function private.guard_archived_property_write()returns trigger language plpgsql security definer set search_path=''as $$
declare pid uuid;closed timestamptz;
begin
 if tg_op='DELETE'then pid:=old.property_id;else pid:=new.property_id;end if;
 select archived_at into closed from public.properties where id=pid for share;
 if closed is not null then raise exception 'This hotel is archived and its records are read-only. Reopen it in Manage properties first.'using errcode='55000';end if;
 if tg_op='UPDATE'and old.property_id is distinct from new.property_id then
  select archived_at into closed from public.properties where id=old.property_id for share;
  if closed is not null then raise exception 'Archived hotel records cannot be moved.'using errcode='55000';end if;
 end if;
 if tg_op='DELETE'then return old;end if;return new;
end $$;
revoke all on function private.guard_archived_property_write()from public,anon,authenticated,service_role;
do $$declare n text;begin
 -- Operational records/configuration are immutable. Delivery queues and audit logs may settle safely.
 foreach n in array array['reservations','accommodation_types','accommodation_units','unit_holds','rate_plans','orders','order_items','menu_items','menu_categories','folios','folio_items','payments','refunds','invoices','credit_notes','tasks','task_checklists','task_comments','guest_requests','guest_request_comments','guest_request_feedback','guest_stay_requests','guest_arrival_details','guest_documents','document_reviews','property_settings','property_memberships','user_roles','departments','service_catalog','service_categories','service_routing_rules','hotel_message_photos','whatsapp_connections','channel_connections','whatsapp_guest_authorizations','whatsapp_marketing_permissions','whatsapp_automation_rules','whatsapp_campaigns','whatsapp_guest_menu','whatsapp_guest_settings','whatsapp_guest_journeys','whatsapp_template_drafts','whatsapp_template_assets','channel_products','channel_rate_calendar','channel_unit_mappings','channel_rate_mappings']loop
  execute format('create trigger archived_property_write before insert or update or delete on public.%I for each row execute function private.guard_archived_property_write()',n);
 end loop;
end $$;
create function private.guard_property_lifecycle_fields()returns trigger language plpgsql set search_path=''as $$
begin
 if tg_op='INSERT'and(new.archived_at is not null or new.archived_by is not null or new.closure_reason<>'')then raise exception 'Create an active hotel before closing it.'using errcode='55000';end if;
 if tg_op='UPDATE'and old.archived_at is not null and new.archived_at is not null then raise exception 'Archived hotel settings are read-only. Reopen it first.'using errcode='55000';end if;
 return new;
end $$;
revoke all on function private.guard_property_lifecycle_fields()from public,anon,authenticated,service_role;
create trigger property_lifecycle_fields before insert or update on public.properties for each row execute function private.guard_property_lifecycle_fields();

-- Portal holders cannot continue transactions against a closed hotel.
alter function private.portal_reservation(text)rename to portal_reservation_before_closure;
revoke all on function private.portal_reservation_before_closure(text)from public,anon,authenticated,service_role;
create function private.portal_reservation(p_token text)returns public.reservations language plpgsql security definer set search_path=''as $$
declare r public.reservations;
begin
 r:=private.portal_reservation_before_closure(p_token);
 perform 1 from public.properties where id=r.property_id and archived_at is null for share;
 if not found then raise exception 'This hotel has closed. Contact the hotel directly.'using errcode='42501';end if;
 return r;
end $$;
revoke all on function private.portal_reservation(text)from public,anon,authenticated,service_role;

create function public.property_lifecycle_context(p_property uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare p public.properties;
begin
 select *into p from public.properties where id=p_property;
 if p.id is null or not private.is_tenant_admin(p.tenant_id)then raise exception 'Business administrator access required.'using errcode='42501';end if;
 return jsonb_build_object('property',to_jsonb(p),'can_change',private.is_tenant_owner(p.tenant_id),'stays',(select count(*)from public.reservations where property_id=p.id and status in('confirmed','checked_in')),'orders',(select count(*)from public.orders where property_id=p.id and status in('placed','preparing','ready')),'open_folios',(select count(*)from public.folios where property_id=p.id and status='open'),'channels',(select count(*)from public.channel_connections where property_id=p.id and status='active'),'sending',(select count(*)from public.messages where property_id=p.id and status='sending'),'history',coalesce((select jsonb_agg(to_jsonb(e))from(select action,reason,created_at from private.property_lifecycle_events where property_id=p.id order by created_at desc,id desc limit 20)e),'[]'));
end $$;
revoke all on function public.property_lifecycle_context(uuid)from public,anon;grant execute on function public.property_lifecycle_context(uuid)to authenticated;

create function public.set_property_archived(p_property uuid,p_version integer,p_archive boolean,p_name text,p_reason text,p_external_closed boolean default false)returns void language plpgsql security definer set search_path=''as $$
declare p public.properties;
begin
 -- Tenant first, matching property creation/reopening plan locks.
 select *into p from public.properties where id=p_property;
 if p.id is null or not private.is_tenant_owner(p.tenant_id)then raise exception 'Only the business owner can close or reopen a hotel.'using errcode='42501';end if;
 perform 1 from public.tenants where id=p.tenant_id for update;
 select *into p from public.properties where id=p_property for update;
 if p.version is distinct from p_version then raise exception 'Hotel details changed. Refresh and review again.'using errcode='40001';end if;
 if p_archive is null or p_name is distinct from p.name or length(trim(coalesce(p_reason,'')))not between 5 and 1000 then raise exception 'Type the hotel name exactly and give a reason (5–1000 characters).'using errcode='22023';end if;
 if p_archive=(p.archived_at is not null)then return;end if;
 if p_archive then
  if p_external_closed is not true then raise exception 'Confirm that bookings and sales are closed in your OTA dashboards.'using errcode='22023';end if;
  if exists(select 1 from public.reservations where property_id=p.id and status in('confirmed','checked_in'))or exists(select 1 from public.orders where property_id=p.id and status in('placed','preparing','ready'))then raise exception 'Resolve every confirmed/in-house stay and unfinished food order before closing this hotel.'using errcode='55000';end if;
  perform 1 from public.messages where property_id=p.id and status in('queued','sending')for update;
  perform 1 from public.sync_jobs where property_id=p.id and status in('queued','running')for update;
  perform 1 from public.channel_poll_state where property_id=p.id for update;
  if exists(select 1 from public.messages where property_id=p.id and status='sending')or exists(select 1 from public.sync_jobs where property_id=p.id and status='running')or exists(select 1 from public.channel_poll_state where property_id=p.id and locked_until>now())then raise exception 'A delivery or channel sync is in progress. Wait for it to finish, then refresh and close the hotel.'using errcode='55000';end if;
  update public.whatsapp_connections set status='disabled'where property_id=p.id;
  delete from private.whatsapp_credentials where property_id=p.id;
  update private.whatsapp_setup_sessions set consumed=true where property_id=p.id;
  update private.whatsapp_consent_challenges set cancelled_at=clock_timestamp()where property_id=p.id and consumed_at is null and cancelled_at is null;
  update public.whatsapp_automation_rules set enabled=false where property_id=p.id and enabled;
  update public.whatsapp_guest_menu set enabled=false,version=version+1 where property_id=p.id;
  update public.whatsapp_campaigns set status='cancelled',version=version+1,last_error='Hotel closed and archived.'where property_id=p.id and status in('scheduled','running','blocked');
  update public.whatsapp_automation_events set state='skipped',reason='Hotel closed and archived.'where property_id=p.id and state in('pending','blocked','queued');
  update public.whatsapp_campaign_recipients set state='skipped',skip_reason='Hotel closed and archived.'where property_id=p.id and state in('pending','queued');
  update public.messages set status='failed',error='Hotel closed and archived.',locked_at=null where property_id=p.id and direction='out'and status='queued';
  update public.channel_connections set status='paused'where property_id=p.id;
  update public.sync_jobs set status='superseded',finished_at=now(),error='Hotel closed and archived.'where property_id=p.id and status='queued';
  update public.guest_access_tokens set revoked_at=now()where property_id=p.id and revoked_at is null;
  update public.properties set archived_at=clock_timestamp(),archived_by=auth.uid(),closure_reason=trim(p_reason)where id=p.id;
 else
  update public.properties set archived_at=null,archived_by=null,closure_reason=''where id=p.id;
 end if;
 insert into private.property_lifecycle_events(property_id,action,reason,actor)values(p.id,case when p_archive then'archived'else'reopened'end,trim(p_reason),auth.uid());
end $$;
revoke all on function public.set_property_archived(uuid,integer,boolean,text,text,boolean)from public,anon;grant execute on function public.set_property_archived(uuid,integer,boolean,text,text,boolean)to authenticated;

-- Defense in depth: old queued work must remain unsendable after reopening too.
alter function private.inbox_delivery_error(uuid)rename to inbox_delivery_error_before_closure;
revoke all on function private.inbox_delivery_error_before_closure(uuid)from public,anon,authenticated,service_role;
create function private.inbox_delivery_error(p_message uuid)returns text language plpgsql stable security definer set search_path=''as $$
begin
 if exists(select 1 from public.messages m join public.properties p on p.id=m.property_id where m.id=p_message and p.archived_at is not null)then return 'Hotel closed and archived.';end if;
 return private.inbox_delivery_error_before_closure(p_message);
end $$;
revoke all on function private.inbox_delivery_error(uuid)from public,anon,authenticated,service_role;
