-- Milestone 4: internal staff tasks + housekeeping. Guest requests are a separate domain (milestone 5);
-- tasks only carry a nullable guest_request_id for the future link.

create function private.shares_tenant_with(u uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.tenant_memberships a
                 join public.tenant_memberships b on b.tenant_id = a.tenant_id
                 where a.user_id = u and b.user_id = (select auth.uid()))
$$;
revoke all on function private.shares_tenant_with(uuid) from public, anon;
grant execute on function private.shares_tenant_with(uuid) to authenticated;

-- Colleagues can see each other's profile (needed to pick assignees).
create policy profiles_select_colleagues on public.profiles for select to authenticated
  using (private.shares_tenant_with(id));

create table public.departments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  name text not null,
  unique (id, property_id),
  unique (property_id, name),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade
);

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  title text not null check (length(trim(title)) > 0),
  description text,
  kind text not null default 'general' check (kind in ('housekeeping', 'maintenance', 'general')),
  status text not null default 'open' check (status in ('open', 'in_progress', 'done', 'cancelled')),
  priority text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  assignee_id uuid,
  department_id uuid,
  unit_id uuid,
  reservation_id uuid,
  guest_request_id uuid,                 -- FK added with the guest-requests domain
  due_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  unique (id, property_id),
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade,
  foreign key (property_id, assignee_id) references public.property_memberships (property_id, user_id) on delete set null (assignee_id),
  foreign key (department_id, property_id) references public.departments (id, property_id),
  foreign key (unit_id, property_id) references public.accommodation_units (id, property_id),
  foreign key (reservation_id, property_id) references public.reservations (id, property_id)
);
create index on public.tasks (property_id, status);
create index on public.tasks (assignee_id) where assignee_id is not null;
create unique index tasks_one_open_housekeeping_per_unit on public.tasks (unit_id)
  where kind = 'housekeeping' and status in ('open', 'in_progress');

create table public.task_checklists (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  task_id uuid not null,
  label text not null,
  done boolean not null default false,
  position int not null default 0,
  foreign key (task_id, property_id) references public.tasks (id, property_id) on delete cascade,
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade
);

create table public.task_comments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  task_id uuid not null,
  author_id uuid not null references public.profiles(id),
  body text not null check (length(trim(body)) > 0),
  created_at timestamptz not null default now(),
  foreign key (task_id, property_id) references public.tasks (id, property_id) on delete cascade,
  foreign key (property_id, tenant_id) references public.properties (id, tenant_id) on delete cascade
);

create table public.task_events (           -- append-only
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  task_id uuid not null,
  event_type text not null,
  actor_id uuid,
  details jsonb not null default '{}',
  created_at timestamptz not null default now(),
  foreign key (task_id, property_id) references public.tasks (id, property_id) on delete cascade
);
create index on public.task_events (task_id, created_at);
-- task_attachments arrive with the Storage/documents work.

-- ---------- RLS ----------
alter table public.departments enable row level security;
alter table public.tasks enable row level security;
alter table public.task_checklists enable row level security;
alter table public.task_comments enable row level security;
alter table public.task_events enable row level security;

create policy departments_select on public.departments for select to authenticated using (private.has_property_access(property_id));
create policy departments_write on public.departments for all to authenticated
  using (private.has_permission(property_id, 'staff.manage')) with check (private.has_permission(property_id, 'staff.manage'));

-- Managers (tasks.assign) see everything; other staff see their own tasks and unassigned ones they may claim.
create policy tasks_select on public.tasks for select to authenticated using (
  private.has_permission(property_id, 'tasks.assign')
  or assignee_id = (select auth.uid())
  or (private.has_permission(property_id, 'tasks.read') and assignee_id is null)
);
-- No direct write policies on tasks: use the functions below.

create policy checklists_select on public.task_checklists for select to authenticated
  using (exists (select 1 from public.tasks t where t.id = task_id));
create policy checklists_manage on public.task_checklists for all to authenticated
  using (private.has_permission(property_id, 'tasks.assign')) with check (private.has_permission(property_id, 'tasks.assign'));
create policy checklists_toggle on public.task_checklists for update to authenticated
  using (exists (select 1 from public.tasks t where t.id = task_id and t.assignee_id = (select auth.uid())))
  with check (exists (select 1 from public.tasks t where t.id = task_id and t.assignee_id = (select auth.uid())));

create policy comments_select on public.task_comments for select to authenticated
  using (exists (select 1 from public.tasks t where t.id = task_id));
create policy comments_insert on public.task_comments for insert to authenticated
  with check (author_id = (select auth.uid()) and exists (select 1 from public.tasks t where t.id = task_id));

create policy task_events_select on public.task_events for select to authenticated
  using (exists (select 1 from public.tasks t where t.id = task_id));

-- ---------- functions ----------
create function private.lock_task(p_id uuid) returns public.tasks
language plpgsql security definer set search_path = '' as $$
declare t public.tasks;
begin
  select * into t from public.tasks where id = p_id for update;
  if not found then raise exception 'not permitted' using errcode = '42501'; end if;
  return t;
end $$;
revoke all on function private.lock_task(uuid) from public, anon;

create function public.create_task(
  p_property uuid, p_title text, p_kind text default 'general', p_priority text default 'normal',
  p_assignee uuid default null, p_unit uuid default null, p_due timestamptz default null, p_description text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_tenant uuid; v_id uuid;
begin
  select tenant_id into v_tenant from public.properties where id = p_property;
  if v_tenant is null or not private.has_permission(p_property, 'tasks.assign') then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  insert into public.tasks (tenant_id, property_id, title, description, kind, priority, assignee_id, unit_id, due_at, created_by)
  values (v_tenant, p_property, p_title, p_description, p_kind, p_priority, p_assignee, p_unit, p_due, auth.uid())
  returning id into v_id;
  insert into public.task_events (tenant_id, property_id, task_id, event_type, actor_id, details)
  values (v_tenant, p_property, v_id, 'created', auth.uid(), jsonb_build_object('assignee', p_assignee));
  return v_id;
end $$;

create function public.assign_task(p_id uuid, p_assignee uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare t public.tasks;
begin
  t := private.lock_task(p_id);
  if not private.has_permission(t.property_id, 'tasks.assign') then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  update public.tasks set assignee_id = p_assignee, updated_at = now() where id = p_id;  -- FK: assignee must be a property member
  insert into public.task_events (tenant_id, property_id, task_id, event_type, actor_id, details)
  values (t.tenant_id, t.property_id, p_id, 'assigned', auth.uid(), jsonb_build_object('assignee', p_assignee));
end $$;

create function public.claim_task(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare t public.tasks;
begin
  t := private.lock_task(p_id);
  if not private.has_permission(t.property_id, 'tasks.write') then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if t.assignee_id is not null or t.status <> 'open' then
    raise exception 'task is not available to claim' using errcode = '22023';
  end if;
  update public.tasks set assignee_id = auth.uid(), updated_at = now() where id = p_id;
  insert into public.task_events (tenant_id, property_id, task_id, event_type, actor_id)
  values (t.tenant_id, t.property_id, p_id, 'claimed', auth.uid());
end $$;

create function public.set_task_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
declare t public.tasks; v_assigner boolean; v_mine boolean;
begin
  t := private.lock_task(p_id);
  v_assigner := private.has_permission(t.property_id, 'tasks.assign');
  v_mine := t.assignee_id = auth.uid() and private.has_permission(t.property_id, 'tasks.write');
  if not (v_assigner or v_mine) then raise exception 'not permitted' using errcode = '42501'; end if;
  if (t.status, p_status) not in (('open','in_progress'), ('open','done'), ('in_progress','done'), ('in_progress','open'),
                                  ('open','cancelled'), ('in_progress','cancelled'), ('done','open'), ('cancelled','open')) then
    raise exception 'invalid transition % -> %', t.status, p_status using errcode = '22023';
  end if;
  if (p_status = 'cancelled' or t.status in ('done', 'cancelled')) and not v_assigner then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  update public.tasks set
    status = p_status,
    started_at = case when p_status = 'in_progress' then coalesce(started_at, now()) else started_at end,
    completed_at = case when p_status = 'done' then now() else null end,
    updated_at = now()
  where id = p_id;

  -- Housekeeping tasks drive the unit's status; the unit becomes sellable again when cleaning is done.
  if t.kind = 'housekeeping' and t.unit_id is not null then
    update public.accommodation_units set housekeeping_status = case p_status
        when 'in_progress' then 'in_progress' when 'done' then 'clean' when 'open' then 'dirty' else housekeeping_status end
      where id = t.unit_id;
  end if;

  insert into public.task_events (tenant_id, property_id, task_id, event_type, actor_id, details)
  values (t.tenant_id, t.property_id, p_id, 'status_changed', auth.uid(), jsonb_build_object('from', t.status, 'to', p_status));
end $$;

-- Checkout now also raises one housekeeping task per unit (deduplicated by the partial unique index).
create or replace function public.check_out_reservation(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.reservations; v record; v_task uuid;
begin
  r := private.lock_reservation(p_id, 'frontdesk.manage');
  if r.status <> 'checked_in' then raise exception 'cannot check out from status %', r.status using errcode = '22023'; end if;
  update public.reservations set status = 'checked_out', checked_out_at = now() where id = p_id;

  for v in select h.unit_id, u.name from public.unit_holds h
           join public.accommodation_units u on u.id = h.unit_id
           where h.reservation_id = p_id and h.active
  loop
    update public.accommodation_units set housekeeping_status = 'dirty' where id = v.unit_id;
    v_task := null;
    insert into public.tasks (tenant_id, property_id, title, kind, unit_id, reservation_id, created_by)
    values (r.tenant_id, r.property_id, 'Clean unit ' || v.name, 'housekeeping', v.unit_id, p_id, auth.uid())
    on conflict (unit_id) where kind = 'housekeeping' and status in ('open', 'in_progress') do nothing
    returning id into v_task;
    if v_task is not null then
      insert into public.task_events (tenant_id, property_id, task_id, event_type, actor_id, details)
      values (r.tenant_id, r.property_id, v_task, 'created', auth.uid(), jsonb_build_object('source', 'checkout'));
    end if;
  end loop;

  insert into public.reservation_events (tenant_id, property_id, reservation_id, event_type, actor_id)
  values (r.tenant_id, r.property_id, p_id, 'checked_out', auth.uid());
end $$;

revoke execute on function
  public.create_task(uuid, text, text, text, uuid, uuid, timestamptz, text), public.assign_task(uuid, uuid),
  public.claim_task(uuid), public.set_task_status(uuid, text) from public, anon;
grant execute on function
  public.create_task(uuid, text, text, text, uuid, uuid, timestamptz, text), public.assign_task(uuid, uuid),
  public.claim_task(uuid), public.set_task_status(uuid, text) to authenticated;
