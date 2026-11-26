-- Permanent, platform-admin deletion. Storage is removed through the Storage API first.
-- The receipt deliberately has no hotel FK: it survives deletion without retaining guest data.
create table private.hotel_deletions(
 id uuid primary key, property_id uuid not null unique, tenant_id uuid not null,
 hotel_name text not null, actor_id uuid not null, reason text not null,
 state text not null default 'files' check(state in('files','complete')),
 scope jsonb not null, guest_ids uuid[] not null default '{}',
 created_at timestamptz not null default now(), completed_at timestamptz
);
revoke all on private.hotel_deletions from public,anon,authenticated,service_role;

-- Child records are owned by a hotel. Raw authenticated DELETE remains denied by RLS.
alter table public.credit_notes drop constraint credit_notes_property_id_tenant_id_fkey, add constraint credit_notes_property_id_tenant_id_fkey foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade;
alter table public.billing_events drop constraint billing_events_property_id_tenant_id_fkey, add constraint billing_events_property_id_tenant_id_fkey foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade;
alter table public.night_audit_runs drop constraint night_audit_runs_property_id_tenant_id_fkey, add constraint night_audit_runs_property_id_tenant_id_fkey foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade;
alter table private.property_lifecycle_events drop constraint property_lifecycle_events_property_id_fkey, add constraint property_lifecycle_events_property_id_fkey foreign key(property_id)references public.properties(id)on delete cascade;
alter table private.whatsapp_template_deletions drop constraint whatsapp_template_deletions_property_id_fkey, add constraint whatsapp_template_deletions_property_id_fkey foreign key(property_id)references public.properties(id)on delete cascade;
alter table private.guest_identity_audit drop constraint guest_identity_audit_property_id_fkey, add constraint guest_identity_audit_property_id_fkey foreign key(property_id)references public.properties(id)on delete cascade;
alter table private.frontdesk_batches drop constraint frontdesk_batches_property_id_fkey, add constraint frontdesk_batches_property_id_fkey foreign key(property_id)references public.properties(id)on delete cascade;
alter table public.inbox_photo_uploads drop constraint inbox_photo_uploads_property_id_fkey, add constraint inbox_photo_uploads_property_id_fkey foreign key(property_id)references public.properties(id)on delete cascade;
alter table public.hotel_payment_connections drop constraint hotel_payment_connections_property_id_tenant_id_fkey, add constraint hotel_payment_connections_property_id_tenant_id_fkey foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade;
alter table public.hotel_payment_requests drop constraint hotel_payment_requests_property_id_tenant_id_fkey, add constraint hotel_payment_requests_property_id_tenant_id_fkey foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade;
alter table public.whatsapp_guest_feedback drop constraint whatsapp_guest_feedback_property_id_tenant_id_fkey, add constraint whatsapp_guest_feedback_property_id_tenant_id_fkey foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade;
alter table public.whatsapp_default_setup drop constraint whatsapp_default_setup_property_id_fkey, add constraint whatsapp_default_setup_property_id_fkey foreign key(property_id)references public.properties(id)on delete cascade;
alter table public.whatsapp_default_templates drop constraint whatsapp_default_templates_property_id_fkey, add constraint whatsapp_default_templates_property_id_fkey foreign key(property_id)references public.properties(id)on delete cascade;
alter table public.whatsapp_template_replacements drop constraint whatsapp_template_replacements_property_id_fkey, add constraint whatsapp_template_replacements_property_id_fkey foreign key(property_id)references public.properties(id)on delete cascade;

-- Audited missing ownership edges: these four tables are not reachable through
-- existing cascades (payments/refunds/invoices use ledger NO ACTION references;
-- menu_item_variants uses a menu-item NO ACTION reference).
alter table public.payments add constraint payments_hotel_ownership foreign key(property_id)references public.properties(id)on delete cascade;
alter table public.refunds add constraint refunds_hotel_ownership foreign key(property_id)references public.properties(id)on delete cascade;
alter table public.invoices add constraint invoices_hotel_ownership foreign key(property_id)references public.properties(id)on delete cascade;
alter table public.menu_item_variants add constraint variants_hotel_ownership foreign key(property_id)references public.properties(id)on delete cascade;
alter table private.hotel_payment_credentials drop constraint hotel_payment_credentials_connection_id_fkey,
 add constraint hotel_payment_credentials_connection_id_fkey foreign key(connection_id)references public.hotel_payment_connections(id)on delete cascade;
-- Historical webhook deduplication records are also hotel-owned.
alter table private.hotel_payment_webhooks add constraint hotel_payment_webhooks_connection_fkey foreign key(connection_id)references public.hotel_payment_connections(id)on delete cascade not valid;

-- Explicit cross-record links retain their normal immediate checks. Only the
-- backend purge defers them while removing sibling branches of the hotel graph,
-- then validates every FK before marking the job complete. No trigger is disabled.
alter table public.accommodation_units alter constraint accommodation_units_type_id_property_id_fkey deferrable initially immediate;
alter table public.billing_events alter constraint billing_events_reservation_id_property_id_fkey deferrable initially immediate;
alter table public.channel_rate_calendar alter constraint channel_rate_calendar_rate_plan_id_property_id_fkey deferrable initially immediate;
alter table public.channel_rate_calendar alter constraint channel_rate_calendar_type_id_property_id_fkey deferrable initially immediate;
alter table public.credit_notes alter constraint credit_notes_folio_id_property_id_fkey deferrable initially immediate;
alter table public.credit_notes alter constraint credit_notes_invoice_id_fkey deferrable initially immediate;
alter table public.credit_notes alter constraint credit_notes_refund_id_fkey deferrable initially immediate;
alter table public.folio_items alter constraint folio_items_order_id_property_id_fkey deferrable initially immediate;
alter table public.folios alter constraint folios_reservation_id_property_id_fkey deferrable initially immediate;
alter table public.guest_requests alter constraint guest_requests_catalog_id_property_id_fkey deferrable initially immediate;
alter table public.guest_requests alter constraint guest_requests_reservation_id_property_id_fkey deferrable initially immediate;
alter table public.guest_requests alter constraint guest_requests_unit_id_property_id_fkey deferrable initially immediate;
alter table public.hotel_payment_requests alter constraint hotel_payment_requests_connection_id_property_id_fkey deferrable initially immediate;
alter table public.hotel_payment_requests alter constraint hotel_payment_requests_conversation_id_fkey deferrable initially immediate;
alter table public.hotel_payment_requests alter constraint hotel_payment_requests_folio_id_property_id_fkey deferrable initially immediate;
alter table public.hotel_payment_requests alter constraint hotel_payment_requests_link_message_id_fkey deferrable initially immediate;
alter table public.hotel_payment_requests alter constraint hotel_payment_requests_receipt_message_id_fkey deferrable initially immediate;
alter table public.hotel_payment_requests alter constraint hotel_payment_requests_reservation_id_property_id_fkey deferrable initially immediate;
alter table public.hotel_payment_requests alter constraint hotel_payment_requests_source_message_id_fkey deferrable initially immediate;
alter table public.inbox_photo_uploads alter constraint inbox_photo_uploads_conversation_id_fkey deferrable initially immediate;
alter table public.invoices alter constraint invoices_folio_id_property_id_fkey deferrable initially immediate;
alter table public.menu_items alter constraint menu_items_category_id_property_id_fkey deferrable initially immediate;
alter table public.menu_items alter constraint menu_items_image_id_property_id_fkey deferrable initially immediate;
alter table public.menu_item_variants alter constraint menu_item_variants_menu_item_id_property_id_fkey deferrable initially immediate;
alter table public.messages alter constraint messages_inbox_photo_id_fkey deferrable initially immediate;
alter table public.messages alter constraint messages_journey_reservation_fkey deferrable initially immediate;
alter table public.messages alter constraint messages_payment_request_id_fkey deferrable initially immediate;
alter table public.order_commands alter constraint order_commands_menu_id_property_id_fkey deferrable initially immediate;
alter table public.order_items alter constraint order_items_menu_item_id_property_id_fkey deferrable initially immediate;
alter table public.order_items alter constraint order_items_variant_id_property_id_fkey deferrable initially immediate;
alter table public.orders alter constraint orders_guest_request_id_property_id_fkey deferrable initially immediate;
alter table public.orders alter constraint orders_reservation_id_property_id_fkey deferrable initially immediate;
alter table public.orders alter constraint orders_unit_id_property_id_fkey deferrable initially immediate;
alter table public.payments alter constraint payments_folio_id_property_id_fkey deferrable initially immediate;
alter table public.payments alter constraint payments_online_request_id_fkey deferrable initially immediate;
alter table public.payments alter constraint payments_order_id_property_id_fkey deferrable initially immediate;
alter table private.whatsapp_booking_contacts alter constraint whatsapp_booking_contacts_conversation_id_fkey deferrable initially immediate;
alter table private.whatsapp_template_deletions alter constraint whatsapp_template_deletions_connection_id_fkey deferrable initially immediate;
alter table private.whatsapp_template_deletions alter constraint whatsapp_template_deletions_template_id_fkey deferrable initially immediate;
alter table public.refunds alter constraint refunds_payment_id_property_id_fkey deferrable initially immediate;
alter table public.reservation_nightly_prices alter constraint reservation_nightly_prices_type_id_property_id_fkey deferrable initially immediate;
alter table public.reservations alter constraint reservations_rate_plan_id_property_id_fkey deferrable initially immediate;
alter table public.service_catalog alter constraint service_catalog_category_id_property_id_fkey deferrable initially immediate;
alter table public.service_routing_rules alter constraint service_routing_rules_department_id_property_id_fkey deferrable initially immediate;
alter table public.tasks alter constraint tasks_department_id_property_id_fkey deferrable initially immediate;
alter table public.tasks alter constraint tasks_guest_request_id_property_id_fkey deferrable initially immediate;
alter table public.tasks alter constraint tasks_reservation_id_property_id_fkey deferrable initially immediate;
alter table public.tasks alter constraint tasks_unit_id_property_id_fkey deferrable initially immediate;
alter table public.whatsapp_automation_events alter constraint whatsapp_automation_events_rule_id_fkey deferrable initially immediate;
alter table public.whatsapp_default_setup alter constraint whatsapp_default_setup_connection_id_fkey deferrable initially immediate;
alter table public.whatsapp_default_templates alter constraint whatsapp_default_templates_template_id_fkey deferrable initially immediate;
alter table public.whatsapp_guest_authorizations alter constraint whatsapp_guest_authorizations_conversation_id_property_id_fkey deferrable initially immediate;
alter table public.whatsapp_guest_authorizations alter constraint whatsapp_guest_authorizations_source_message_id_fkey deferrable initially immediate;
alter table public.whatsapp_guest_feedback alter constraint whatsapp_guest_feedback_conversation_id_fkey deferrable initially immediate;
alter table public.whatsapp_guest_feedback alter constraint whatsapp_guest_feedback_reservation_id_property_id_fkey deferrable initially immediate;
alter table public.whatsapp_guest_feedback alter constraint whatsapp_guest_feedback_source_message_id_fkey deferrable initially immediate;
alter table public.whatsapp_guest_journeys alter constraint whatsapp_guest_journeys_template_id_property_id_fkey deferrable initially immediate;
alter table public.whatsapp_marketing_permissions alter constraint whatsapp_marketing_permissions_source_message_id_fkey deferrable initially immediate;
alter table public.whatsapp_template_replacements alter constraint whatsapp_template_replacements_old_template_fkey deferrable initially immediate;

-- Feedback prompts and action tokens are indirect hotel records too.
alter table private.whatsapp_feedback_followups drop constraint whatsapp_feedback_followups_conversation_id_fkey,
 add constraint whatsapp_feedback_followups_conversation_id_fkey foreign key(conversation_id)references public.conversations(id)on delete cascade;
alter table private.whatsapp_feedback_followups drop constraint whatsapp_feedback_followups_feedback_id_fkey,
 add constraint whatsapp_feedback_followups_feedback_id_fkey foreign key(feedback_id)references public.whatsapp_guest_feedback(id)on delete cascade;
alter table private.whatsapp_journey_actions alter constraint whatsapp_journey_actions_source_message_id_fkey deferrable initially immediate;

create function private.hotel_deletion_files(p_property uuid)returns table(bucket text,path text)
language sql stable security definer set search_path=''as $$
 select o.bucket_id,o.name from storage.objects o join private.hotel_deletions j on j.property_id=p_property
 where (o.bucket_id in('hotel-whatsapp-photos','food-menu-photos','whatsapp-inbox-photos')and split_part(o.name,'/',1)=p_property::text)
 or(o.bucket_id='guest-documents'and split_part(o.name,'/',1)=j.tenant_id::text and split_part(o.name,'/',2)=p_property::text)
$$;
create function private.hotel_deletion_blockers(p_property uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare reasons jsonb:='[]';begin
 if exists(select 1 from public.messages where property_id=p_property and(status='sending'or delivery_uncertain))then reasons:=reasons||'"Wait for sending or uncertain WhatsApp deliveries to be resolved in the inbox."'::jsonb;end if;
 if exists(select 1 from public.sync_jobs where property_id=p_property and status='running')or exists(select 1 from public.channel_poll_state where property_id=p_property and locked_until>now())then reasons:=reasons||'"Wait for the running channel sync to finish."'::jsonb;end if;
 if exists(select 1 from public.hotel_payment_requests where property_id=p_property and(state in('creating','unknown','ready','cancel_pending')or lease is not null and locked_at>now()-interval '5 minutes'))then reasons:=reasons||'"Resolve pending payment operations and cancel or expire unpaid payment links before deleting."'::jsonb;end if;
 if exists(select 1 from public.whatsapp_default_setup where property_id=p_property and lease is not null and locked_at>now()-interval '5 minutes')
 or exists(select 1 from private.whatsapp_template_deletions where property_id=p_property and state in('pending','uncertain'))then reasons:=reasons||'"Wait for WhatsApp template setup or deletion to finish."'::jsonb;end if;
 if exists(select 1 from private.document_image_jobs j join public.guest_documents d on d.id=j.document_id where d.property_id=p_property and j.lease_id is not null and j.expires_at>now())
 or exists(select 1 from private.document_scan_leases j join public.guest_documents d on d.id=j.document_id where d.property_id=p_property and j.lease_id is not null and j.expires_at>now())then reasons:=reasons||'"Wait for document processing to finish."'::jsonb;end if;
 if exists(select 1 from private.whatsapp_coexistence_sync s join public.whatsapp_connections c on c.id=s.connection_id where c.property_id=p_property and s.lease is not null and s.claimed_at>now()-interval '5 minutes')
 or exists(select 1 from private.whatsapp_coexistence_events s join public.whatsapp_connections c on c.id=s.connection_id where c.property_id=p_property and s.lease is not null and s.claimed_at>now()-interval '5 minutes')then reasons:=reasons||'"Wait for WhatsApp Business app synchronization to finish."'::jsonb;end if;
 return reasons;
end $$;

create function public.platform_hotel_deletion_preview(p_property uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare p public.properties;j private.hotel_deletions;r record;counts jsonb:='{}';n bigint;files bigint;begin
 if not exists(select 1 from public.platform_admins where user_id=auth.uid())then raise exception 'Platform administrator access required.'using errcode='42501';end if;
 select *into j from private.hotel_deletions where property_id=p_property;
 if j.id is not null then return jsonb_build_object('id',p_property,'tenant',j.tenant_id,'name',j.hotel_name,'job',j.id,'state',j.state,'counts',j.scope,'files_remaining',(select count(*)from private.hotel_deletion_files(p_property)));end if;
 select *into p from public.properties where id=p_property;
 if p.id is null then raise exception 'Hotel not found.'using errcode='P0002';end if;
 -- Aggregate counts only: platform access does not expose guest messages or document contents.
 for r in select c.oid::regclass tbl,c.relname from pg_class c join pg_namespace s on s.oid=c.relnamespace join pg_attribute a on a.attrelid=c.oid and a.attname='property_id'and a.attnum>0 and not a.attisdropped
 where s.nspname='public'and c.relkind='r'loop
  execute format('select count(*)from %s where property_id=$1',r.tbl)into n using p.id;
  if n>0 then counts:=counts||jsonb_build_object(r.relname,n);end if;
 end loop;
 select count(*)into files from storage.objects o where(o.bucket_id in('hotel-whatsapp-photos','food-menu-photos','whatsapp-inbox-photos')and split_part(o.name,'/',1)=p.id::text)or(o.bucket_id='guest-documents'and split_part(o.name,'/',1)=p.tenant_id::text and split_part(o.name,'/',2)=p.id::text);
 return jsonb_build_object('id',p.id,'tenant',p.tenant_id,'name',p.name,'version',p.version,'state','review','counts',counts,'files_remaining',files,'blockers',private.hotel_deletion_blockers(p.id));
end $$;
revoke all on function public.platform_hotel_deletion_preview(uuid)from public,anon;
grant execute on function public.platform_hotel_deletion_preview(uuid)to authenticated;

-- The deletion lock participates in all property writes, including service-role webhooks.
create function private.guard_hotel_deletion_write()returns trigger language plpgsql security definer set search_path=''as $$
declare pid uuid;old_pid uuid;begin
 if tg_op='DELETE'then pid:=old.property_id;else pid:=new.property_id;end if;
 perform 1 from public.properties where id=pid for share;
 if found and exists(select 1 from private.hotel_deletions where property_id=pid)then raise exception 'This hotel is being permanently deleted.'using errcode='55000';end if;
 if tg_op='UPDATE'and old.property_id is distinct from new.property_id then
  old_pid:=old.property_id;perform 1 from public.properties where id=old_pid for share;
  if exists(select 1 from private.hotel_deletions where property_id=old_pid)then raise exception 'This hotel is being permanently deleted.'using errcode='55000';end if;
 end if;
 if tg_op='DELETE'then return old;end if;return new;
end $$;
do $$declare r record;begin
 for r in select c.oid::regclass tbl from pg_class c join pg_namespace s on s.oid=c.relnamespace join pg_attribute a on a.attrelid=c.oid and a.attname='property_id'and a.attnum>0 and not a.attisdropped
 where s.nspname in('public','private')and c.relkind='r'and c.oid<>'private.hotel_deletions'::regclass loop
  execute format('create trigger hotel_deletion_write before insert or update or delete on %s for each row execute function private.guard_hotel_deletion_write()',r.tbl);
 end loop;
end $$;
create function private.guard_hotel_deletion_identity()returns trigger language plpgsql security definer set search_path=''as $$
begin
 if exists(select 1 from private.hotel_deletions where property_id=old.id)then raise exception 'This hotel is being permanently deleted and cannot be reopened or edited.'using errcode='55000';end if;
 return new;
end $$;
create trigger hotel_deletion_identity before update on public.properties for each row execute function private.guard_hotel_deletion_identity();
-- Old signed upload URLs cannot recreate files during/after deletion. Storage removal is allowed.
create function private.guard_deleted_hotel_upload()returns trigger language plpgsql security definer set search_path=''as $$
declare part text;pid uuid;begin
 if new.bucket_id in('hotel-whatsapp-photos','food-menu-photos','whatsapp-inbox-photos')then part:=split_part(new.name,'/',1);
 elsif new.bucket_id='guest-documents'then part:=split_part(new.name,'/',2);else return new;end if;
 if part!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'then return new;end if;
 pid:=part::uuid;perform 1 from public.properties where id=pid for share;
 if exists(select 1 from private.hotel_deletions where property_id=pid)then raise exception 'This hotel no longer accepts uploads.'using errcode='55000';end if;
 return new;
end $$;
create trigger deleted_hotel_upload before insert or update of name,bucket_id on storage.objects for each row execute function private.guard_deleted_hotel_upload();
-- Keep a frozen hotel out of staff permission checks, even for business owners.
create or replace function private.has_property_access(p uuid)returns boolean language sql stable security definer set search_path=''as $$
 select not exists(select 1 from private.hotel_deletions where property_id=p)and exists(select 1 from public.properties pr where pr.id=p and private.tenant_is_active(pr.tenant_id)and(private.is_tenant_admin(pr.tenant_id)or pr.archived_at is null and exists(select 1 from public.property_memberships pm where pm.property_id=p and pm.user_id=auth.uid())))
$$;
create or replace function private.has_permission(p uuid,perm text)returns boolean language sql stable security definer set search_path=''as $$
 select not exists(select 1 from private.hotel_deletions where property_id=p)and exists(select 1 from public.properties pr where pr.id=p and private.tenant_is_active(pr.tenant_id)
 and(pr.archived_at is null or private.is_tenant_admin(pr.tenant_id)and right(perm,5)='.read')
 and(private.is_tenant_admin(pr.tenant_id)or exists(select 1 from public.user_roles ur join public.role_permissions rp on rp.role_id=ur.role_id where ur.property_id=p and ur.user_id=auth.uid()and rp.permission_key=perm)))
$$;

create function public.platform_hotel_deletion_begin(p_property uuid,p_actor uuid,p_request uuid,p_version integer,p_name text,p_reason text)returns uuid
language plpgsql security definer set search_path=''as $$
declare p public.properties;j private.hotel_deletions;scope jsonb;guests uuid[];begin
 if not exists(select 1 from public.platform_admins where user_id=p_actor)then raise exception 'Platform administrator access required.'using errcode='42501';end if;
 if p_request is null or length(trim(coalesce(p_reason,'')))not between 5 and 1000 then raise exception 'Give a reason of 5–1,000 characters.'using errcode='22023';end if;
 select *into p from public.properties where id=p_property;
 perform 1 from public.tenants where id=p.tenant_id for update;
 select *into p from public.properties where id=p_property for update;
 select *into j from private.hotel_deletions where property_id=p_property;
 if j.id is not null then return j.id;end if;
 if p.id is null then raise exception 'Hotel not found.'using errcode='P0002';end if;
 if p.name is distinct from p_name or p.version is distinct from p_version then raise exception 'Hotel details changed, or its name does not match. Refresh and review again.'using errcode='40001';end if;
 -- Lock rows claimed by workers before evaluating their state.
 perform 1 from public.messages where property_id=p.id for update;
 perform 1 from public.sync_jobs where property_id=p.id for update;
 perform 1 from public.channel_poll_state where property_id=p.id for update;
 perform 1 from public.hotel_payment_requests where property_id=p.id for update;
 perform 1 from public.whatsapp_default_setup where property_id=p.id for update;
 if jsonb_array_length(private.hotel_deletion_blockers(p.id))>0 then raise exception '%',private.hotel_deletion_blockers(p.id)->>0 using errcode='55000';end if;
 -- Snapshot counts as the actor, without trusting a caller-supplied manifest.
 perform set_config('request.jwt.claim.sub',p_actor::text,true);
 scope:=public.platform_hotel_deletion_preview(p.id)->'counts';
 select array_agg(distinct guest_id)filter(where guest_id is not null)into guests from(
  select guest_id from public.reservations where property_id=p.id union select guest_id from public.conversations where property_id=p.id
  union select guest_id from public.guest_documents where property_id=p.id union select guest_id from public.whatsapp_guest_authorizations where property_id=p.id
  union select guest_id from private.whatsapp_booking_contacts where property_id=p.id union select guest_id from private.whatsapp_consent_challenges where property_id=p.id
  union select guest_id from public.whatsapp_campaign_recipients where property_id=p.id
  union select consent_confirmation_guest from public.messages where property_id=p.id
 )g;
 -- Active properties must stop integrations before the freeze is installed. Archived ones are already stopped.
 if p.archived_at is null then
  update public.whatsapp_connections set status='disabled'where property_id=p.id;
  update public.channel_connections set status='paused'where property_id=p.id;
  update public.hotel_payment_connections set status='disconnected',checkout_enabled=false where property_id=p.id;
  update public.whatsapp_automation_rules set enabled=false where property_id=p.id;
  update public.whatsapp_campaigns set status='cancelled',version=version+1 where property_id=p.id and status in('scheduled','running','blocked');
  update public.properties set archived_at=now(),archived_by=p_actor,closure_reason='Permanent deletion in progress',version=version+1 where id=p.id;
 end if;
 delete from private.whatsapp_credentials where property_id=p.id;
 delete from private.hotel_payment_credentials where connection_id in(select id from public.hotel_payment_connections where property_id=p.id);
 update public.messages set status='failed',error='Hotel permanently deleted by platform administrator.',locked_at=null where property_id=p.id and direction='out'and status='queued';
 update public.sync_jobs set status='superseded',finished_at=now(),error='Hotel deletion.'where property_id=p.id and status='queued';
 update public.guest_access_tokens set revoked_at=now()where property_id=p.id and revoked_at is null;
 insert into private.hotel_deletions(id,property_id,tenant_id,hotel_name,actor_id,reason,scope,guest_ids)
 values(p_request,p.id,p.tenant_id,p.name,p_actor,trim(p_reason),scope,coalesce(guests,'{}'));
 insert into public.platform_audit_logs(actor_id,tenant_id,action,details)values(p_actor,p.tenant_id,'platform_hotel_deletion_started',jsonb_build_object('property_id',p.id,'hotel',p.name,'reason',trim(p_reason),'request_id',p_request));
 return p_request;
end $$;

-- Strip a deleted hotel's grants from shared business-level access history.
-- Array entries tagged with this property are removed; unrelated entries are preserved.
create function private.without_hotel(p_value jsonb,p_property uuid)returns jsonb
language plpgsql immutable set search_path=''as $$
declare result jsonb;begin
 if jsonb_typeof(p_value)='object'then
  if p_value->>'property_id'=p_property::text then return 'null'::jsonb;end if;
  select coalesce(jsonb_object_agg(key,private.without_hotel(value,p_property)),'{}')into result from jsonb_each(p_value);
 elsif jsonb_typeof(p_value)='array'then
  select coalesce(jsonb_agg(cleaned order by position),'[]')into result from(select private.without_hotel(value,p_property)cleaned,ordinality position from jsonb_array_elements(p_value)with ordinality)x where cleaned<>'null'::jsonb;
 else result:=p_value;end if;
 return result;
end $$;
create function public.platform_hotel_deletion_step(p_job uuid,p_actor uuid)returns jsonb
language plpgsql security definer set search_path=''as $$
declare j private.hotel_deletions;r record;remaining bigint;g uuid;referenced boolean;used boolean;counts jsonb;begin
 if not exists(select 1 from public.platform_admins where user_id=p_actor)then raise exception 'Platform administrator access required.'using errcode='42501';end if;
 select *into j from private.hotel_deletions where id=p_job for update;
 if j.id is null then raise exception 'Deletion request not found.'using errcode='P0002';end if;
 if j.state='complete'then return jsonb_build_object('state','complete','tenant',j.tenant_id,'name',j.hotel_name,'files',jsonb_build_array());end if;
 select count(*)into remaining from private.hotel_deletion_files(j.property_id);
 if remaining>0 then return jsonb_build_object('state','files','remaining',remaining,'files',(select jsonb_agg(to_jsonb(f))from(select *from private.hotel_deletion_files(j.property_id)order by bucket,path limit 100)f));end if;
 -- Finalize only after physical Storage API removal has succeeded for every object.
 set constraints all deferred;
 perform 1 from public.tenants where id=j.tenant_id for update;
 perform 1 from public.properties where id=j.property_id for update;
 delete from public.properties where id=j.property_id;
 set constraints all immediate;
 -- Remove only guest profiles exclusively belonging to this hotel. Respect every declared guest FK.
 foreach g in array j.guest_ids loop
  perform 1 from public.guests where id=g for update;referenced:=false;
  for r in select c.conrelid::regclass tbl,a.attname col from pg_constraint c join pg_attribute a on a.attrelid=c.conrelid and a.attnum=c.conkey[1]
   where c.contype='f'and c.confrelid='public.guests'::regclass loop
   execute format('select exists(select 1 from %s where %I=$1)',r.tbl,r.col)into used using g;
   referenced:=referenced or used;
  end loop;
  if not referenced then delete from public.guests where id=g;end if;
 end loop;
 -- Shared business access history retains other hotels' grants, without this hotel's data.
 update public.staff_invitation_emails e set context=jsonb_build_object('notice','Hotel access changed after permanent deletion.')
 where e.invitation_id in(select i.id from public.staff_invitations i where i.tenant_id=j.tenant_id and exists(select 1 from jsonb_array_elements(i.grants)x where x->>'property_id'=j.property_id::text));
 update public.staff_invitations i set grants=private.without_hotel(i.grants,j.property_id),
 status=case when i.tenant_role='member'and i.status='pending'and private.without_hotel(i.grants,j.property_id)='[]'::jsonb then 'revoked'else i.status end
 where i.tenant_id=j.tenant_id and exists(select 1 from jsonb_array_elements(i.grants)x where x->>'property_id'=j.property_id::text);
 update public.staff_commands set payload=coalesce(nullif(private.without_hotel(payload,j.property_id),'null'::jsonb),'{}'::jsonb)where tenant_id=j.tenant_id and payload::text like '%'||j.property_id::text||'%';
 update public.staff_events set details=coalesce(nullif(private.without_hotel(details,j.property_id),'null'::jsonb),'{}'::jsonb)where tenant_id=j.tenant_id and details::text like '%'||j.property_id::text||'%';
 -- Verify all directly hotel-owned tables, including private jobs/audits/caches, were removed.
 for r in select c.oid::regclass tbl from pg_class c join pg_namespace s on s.oid=c.relnamespace join pg_attribute a on a.attrelid=c.oid and a.attname='property_id'and a.attnum>0 and not a.attisdropped
 where s.nspname in('public','private')and c.relkind='r'and c.oid<>'private.hotel_deletions'::regclass loop
  execute format('select exists(select 1 from %s where property_id=$1)',r.tbl)into used using j.property_id;
  if used then raise exception 'Hotel cleanup is incomplete in %. No database records were deleted; retry or contact support.',r.tbl using errcode='55000';end if;
 end loop;
 update private.hotel_deletions set state='complete',completed_at=now(),guest_ids='{}'where id=j.id;
 insert into public.platform_audit_logs(actor_id,tenant_id,action,details)values(p_actor,j.tenant_id,'platform_hotel_deleted',jsonb_build_object('property_id',j.property_id,'hotel',j.hotel_name,'reason',j.reason,'request_id',j.id,'scope',j.scope));
 return jsonb_build_object('state','complete','tenant',j.tenant_id,'name',j.hotel_name,'files',jsonb_build_array());
end $$;
-- Private helpers and backend mutators must never be callable by browser roles.
revoke all on function private.hotel_deletion_files(uuid),private.hotel_deletion_blockers(uuid),private.guard_hotel_deletion_write(),private.guard_deleted_hotel_upload(),private.guard_hotel_deletion_identity(),private.without_hotel(jsonb,uuid)from public,anon,authenticated,service_role;
revoke all on function public.platform_hotel_deletion_begin(uuid,uuid,uuid,integer,text,text),public.platform_hotel_deletion_step(uuid,uuid)from public,anon,authenticated;
grant execute on function public.platform_hotel_deletion_begin(uuid,uuid,uuid,integer,text,text),public.platform_hotel_deletion_step(uuid,uuid)to service_role;
