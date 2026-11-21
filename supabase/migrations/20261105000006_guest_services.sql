-- Milestone 5: guest services. A guest request is NOT an internal task: separate records,
-- linked by tasks.guest_request_id. Routing rules turn a request into a linked task.
-- Order targets (restaurant/room service) arrive with milestone 7; today a rule can only create a task.

create table public.service_categories (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  name text not null,
  unique (id, property_id),
  unique (property_id, name),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade
);

create table public.service_catalog (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  category_id uuid not null,
  name text not null,
  default_priority text not null default 'normal' check (default_priority in ('low', 'normal', 'high', 'urgent')),
  active boolean not null default true,
  unique (id, property_id),
  unique (property_id, name),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade,
  foreign key (category_id, property_id) references public.service_categories (id, property_id)
);

create table public.service_routing_rules (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  catalog_id uuid not null unique,
  task_kind text not null default 'general' check (task_kind in ('housekeeping', 'maintenance', 'general')),
  department_id uuid,
  default_assignee_id uuid,
  sla_minutes int check (sla_minutes > 0),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade,
  foreign key (catalog_id, property_id) references public.service_catalog (id, property_id) on delete cascade,
  foreign key (department_id, property_id) references public.departments (id, property_id),
  foreign key (property_id, default_assignee_id) references public.property_memberships (property_id, user_id) on delete set null (default_assignee_id)
);

create table public.guest_requests (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  reservation_id uuid not null,                 -- requests are always scoped to a stay
  catalog_id uuid,
  title text not null check (length(trim(title)) > 0),
  notes text,
  status text not null default 'new' check (status in ('new', 'in_progress', 'completed', 'cancelled')),
  priority text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  source text not null check (source in ('staff', 'portal', 'whatsapp', 'qr')),
  unit_id uuid,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (id, property_id),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade,
  foreign key (reservation_id, property_id) references public.reservations (id, property_id),
  foreign key (catalog_id, property_id) references public.service_catalog (id, property_id),
  foreign key (unit_id, property_id) references public.accommodation_units (id, property_id)
);
create index on public.guest_requests (property_id, status);
create index on public.guest_requests (reservation_id);

alter table public.tasks add foreign key (guest_request_id, property_id) references public.guest_requests (id, property_id);
create index on public.tasks (guest_request_id) where guest_request_id is not null;

create table public.guest_request_events (       -- append-only
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  guest_request_id uuid not null,
  event_type text not null,
  actor_id uuid,
  details jsonb not null default '{}',
  created_at timestamptz not null default now(),
  foreign key (guest_request_id, property_id) references public.guest_requests (id, property_id) on delete cascade
);
create index on public.guest_request_events (guest_request_id, created_at);

create table public.guest_request_feedback (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  guest_request_id uuid not null unique,
  rating int not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now(),
  foreign key (guest_request_id, property_id) references public.guest_requests (id, property_id) on delete cascade
);

-- ---------- RLS ----------
alter table public.service_categories enable row level security;
alter table public.service_catalog enable row level security;
alter table public.service_routing_rules enable row level security;
alter table public.guest_requests enable row level security;
alter table public.guest_request_events enable row level security;
alter table public.guest_request_feedback enable row level security;

create policy categories_select on public.service_categories for select to authenticated using (private.has_property_access(property_id));
create policy catalog_select on public.service_catalog for select to authenticated using (private.has_property_access(property_id));
create policy rules_select on public.service_routing_rules for select to authenticated using (private.has_property_access(property_id));
create policy categories_write on public.service_categories for all to authenticated
  using (private.has_permission(property_id, 'staff.manage')) with check (private.has_permission(property_id, 'staff.manage'));
create policy catalog_write on public.service_catalog for all to authenticated
  using (private.has_permission(property_id, 'staff.manage')) with check (private.has_permission(property_id, 'staff.manage'));
create policy rules_write on public.service_routing_rules for all to authenticated
  using (private.has_permission(property_id, 'staff.manage')) with check (private.has_permission(property_id, 'staff.manage'));

-- Request desk staff see requests; a staff member assigned a linked task sees that request.
create policy guest_requests_select on public.guest_requests for select to authenticated using (
  private.has_permission(property_id, 'guest_requests.read')
  or exists (select 1 from public.tasks t where t.guest_request_id = id and t.assignee_id = (select auth.uid()))
);
create policy gr_events_select on public.guest_request_events for select to authenticated
  using (exists (select 1 from public.guest_requests g where g.id = guest_request_id));
create policy gr_feedback_select on public.guest_request_feedback for select to authenticated
  using (private.has_permission(property_id, 'guest_requests.read'));
-- No direct write policies on requests, events or feedback.

-- ---------- core creation (shared by staff RPC now, portal/WhatsApp edge functions later via service role) ----------
create function private.create_guest_request_core(
  p_property uuid, p_reservation uuid, p_catalog uuid, p_title text, p_notes text, p_source text, p_actor uuid
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_res public.reservations; v_item public.service_catalog; v_rule public.service_routing_rules;
  v_unit uuid; v_unit_name text; v_title text; v_id uuid; v_task uuid;
begin
  select * into v_res from public.reservations where id = p_reservation and property_id = p_property;
  if not found or v_res.status not in ('confirmed', 'checked_in') then
    raise exception 'reservation is not active for this property' using errcode = '22023';
  end if;

  if p_catalog is not null then
    select * into v_item from public.service_catalog where id = p_catalog and property_id = p_property and active;
    if not found then raise exception 'unknown or inactive service' using errcode = '22023'; end if;
    select * into v_rule from public.service_routing_rules where catalog_id = p_catalog;
  end if;

  v_title := coalesce(nullif(trim(p_title), ''), v_item.name);
  if v_title is null then raise exception 'title or service required' using errcode = '22023'; end if;

  select h.unit_id, u.name into v_unit, v_unit_name
    from public.unit_holds h join public.accommodation_units u on u.id = h.unit_id
    where h.reservation_id = p_reservation and h.active limit 1;

  insert into public.guest_requests (tenant_id, property_id, reservation_id, catalog_id, title, notes, priority, source, unit_id, created_by)
  values (v_res.tenant_id, p_property, p_reservation, p_catalog, v_title, p_notes,
          coalesce(v_item.default_priority, 'normal'), p_source, v_unit, p_actor)
  returning id into v_id;
  insert into public.guest_request_events (tenant_id, property_id, guest_request_id, event_type, actor_id, details)
  values (v_res.tenant_id, p_property, v_id, 'created', p_actor, jsonb_build_object('source', p_source));

  if v_rule.id is not null then
    -- unit_id stays null on the task on purpose: only turnover cleaning tasks drive unit housekeeping status.
    insert into public.tasks (tenant_id, property_id, title, description, kind, priority, assignee_id, department_id,
                              reservation_id, guest_request_id, due_at, created_by)
    values (v_res.tenant_id, p_property,
            v_title || coalesce(' (unit ' || v_unit_name || ')', ''), p_notes, v_rule.task_kind,
            coalesce(v_item.default_priority, 'normal'), v_rule.default_assignee_id, v_rule.department_id,
            p_reservation, v_id, case when v_rule.sla_minutes is not null then now() + make_interval(mins => v_rule.sla_minutes) end, p_actor)
    returning id into v_task;
    insert into public.task_events (tenant_id, property_id, task_id, event_type, actor_id, details)
    values (v_res.tenant_id, p_property, v_task, 'created', p_actor, jsonb_build_object('guest_request_id', v_id));
    insert into public.guest_request_events (tenant_id, property_id, guest_request_id, event_type, actor_id, details)
    values (v_res.tenant_id, p_property, v_id, 'task_created', p_actor, jsonb_build_object('task_id', v_task));
  end if;
  return v_id;
end $$;
revoke all on function private.create_guest_request_core(uuid, uuid, uuid, text, text, text, uuid) from public, anon, authenticated;
grant usage on schema private to service_role;
grant execute on function private.create_guest_request_core(uuid, uuid, uuid, text, text, text, uuid) to service_role;

create function public.create_guest_request(
  p_property uuid, p_reservation uuid, p_catalog uuid default null, p_title text default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  if not private.has_permission(p_property, 'guest_requests.manage') then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return private.create_guest_request_core(p_property, p_reservation, p_catalog, p_title, p_notes, 'staff', auth.uid());
end $$;

-- ---------- keep request status in step with its linked task ----------
create function private.sync_request_from_task() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_new text;
begin
  if new.guest_request_id is null or new.status = old.status then return new; end if;
  v_new := case new.status when 'in_progress' then 'in_progress' when 'done' then 'completed' when 'cancelled' then 'cancelled' else 'new' end;
  update public.guest_requests
    set status = v_new, updated_at = now(), completed_at = case when v_new = 'completed' then now() end
    where id = new.guest_request_id and status <> v_new;
  if found then
    insert into public.guest_request_events (tenant_id, property_id, guest_request_id, event_type, actor_id, details)
    values (new.tenant_id, new.property_id, new.guest_request_id, 'status_changed', auth.uid(),
            jsonb_build_object('to', v_new, 'via_task', new.id));
  end if;
  return new;
end $$;
create trigger tasks_sync_guest_request after update of status on public.tasks
  for each row execute function private.sync_request_from_task();

-- ---------- request actions ----------
create function private.lock_guest_request(p_id uuid) returns public.guest_requests
language plpgsql security definer set search_path = '' as $$
declare g public.guest_requests;
begin
  select * into g from public.guest_requests where id = p_id for update;
  if not found or not private.has_permission(g.property_id, 'guest_requests.manage') then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return g;
end $$;
revoke all on function private.lock_guest_request(uuid) from public, anon;

create function public.complete_guest_request(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare g public.guest_requests;
begin
  g := private.lock_guest_request(p_id);
  if g.status not in ('new', 'in_progress') then raise exception 'request is already %', g.status using errcode = '22023'; end if;
  if exists (select 1 from public.tasks where guest_request_id = p_id and status in ('open', 'in_progress')) then
    raise exception 'complete the linked task instead' using errcode = '22023';
  end if;
  update public.guest_requests set status = 'completed', completed_at = now(), updated_at = now() where id = p_id;
  insert into public.guest_request_events (tenant_id, property_id, guest_request_id, event_type, actor_id)
  values (g.tenant_id, g.property_id, p_id, 'completed', auth.uid());
end $$;

create function public.cancel_guest_request(p_id uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare g public.guest_requests;
begin
  g := private.lock_guest_request(p_id);
  if g.status not in ('new', 'in_progress') then raise exception 'request is already %', g.status using errcode = '22023'; end if;
  update public.guest_requests set status = 'cancelled', updated_at = now() where id = p_id;
  update public.tasks set status = 'cancelled', updated_at = now() where guest_request_id = p_id and status in ('open', 'in_progress');
  insert into public.guest_request_events (tenant_id, property_id, guest_request_id, event_type, actor_id, details)
  values (g.tenant_id, g.property_id, p_id, 'cancelled', auth.uid(), jsonb_build_object('reason', p_reason));
end $$;

create function public.record_guest_request_feedback(p_id uuid, p_rating int, p_comment text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare g public.guest_requests;
begin
  g := private.lock_guest_request(p_id);
  if g.status <> 'completed' then raise exception 'feedback is only collected for completed requests' using errcode = '22023'; end if;
  insert into public.guest_request_feedback (tenant_id, property_id, guest_request_id, rating, comment)
  values (g.tenant_id, g.property_id, p_id, p_rating, p_comment);
end $$;

revoke execute on function
  public.create_guest_request(uuid, uuid, uuid, text, text), public.complete_guest_request(uuid),
  public.cancel_guest_request(uuid, text), public.record_guest_request_feedback(uuid, int, text) from public, anon;
grant execute on function
  public.create_guest_request(uuid, uuid, uuid, text, text), public.complete_guest_request(uuid),
  public.cancel_guest_request(uuid, text), public.record_guest_request_feedback(uuid, int, text) to authenticated;
