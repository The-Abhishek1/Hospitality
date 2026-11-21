-- Milestone 9: guest portal access, guest documents.
-- Guests are NOT Supabase users. Access = an unguessable, expiring, revocable link scoped to ONE reservation.
-- Only a SHA-256 hash of the token is stored. The portal calls token-scoped functions as `anon`; it never holds a
-- service-role key. Document upload/confirm/scan are service_role-only and driven by edge functions + a scanner.

insert into public.permissions (key, description) values ('documents.review', 'View, approve and reject guest identity documents (access is audited)');
insert into public.role_permissions (role_id, permission_key)
select r.id, 'documents.review' from public.roles r where r.tenant_id is null and r.key in ('front_desk', 'manager');

create table public.guest_access_tokens (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null, reservation_id uuid not null,
  token_hash text not null unique,
  expires_at timestamptz not null, revoked_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  last_used_at timestamptz, use_count int not null default 0,
  foreign key (reservation_id, property_id) references public.reservations (id, property_id) on delete cascade
);
create index on public.guest_access_tokens (reservation_id);

create table public.guest_documents (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null, reservation_id uuid not null, guest_id uuid not null,
  doc_type text not null check (doc_type in ('id_proof', 'passport', 'visa', 'other')),
  storage_path text not null unique,
  mime_type text not null check (mime_type in ('image/jpeg', 'image/png', 'application/pdf')),
  size_bytes int not null check (size_bytes between 1 and 10485760),
  status text not null default 'pending_upload' check (status in ('pending_upload', 'uploaded', 'clean', 'infected', 'approved', 'rejected')),
  created_at timestamptz not null default now(), uploaded_at timestamptz, scanned_at timestamptz,
  unique (id, property_id),
  foreign key (reservation_id, property_id) references public.reservations (id, property_id) on delete cascade,
  foreign key (guest_id, tenant_id) references public.guests (id, tenant_id)
);
create index on public.guest_documents (reservation_id);

create table public.document_reviews (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null, document_id uuid not null,
  decision text not null check (decision in ('approved', 'rejected')), note text,
  reviewed_by uuid references public.profiles(id) on delete set null, created_at timestamptz not null default now(),
  foreign key (document_id, property_id) references public.guest_documents (id, property_id) on delete cascade
);
create table public.document_access_events (      -- append-only: every staff access to a document is logged
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null, property_id uuid not null, document_id uuid not null,
  accessed_by uuid references public.profiles(id) on delete set null, reason text,
  created_at timestamptz not null default now(),
  foreign key (document_id, property_id) references public.guest_documents (id, property_id) on delete cascade
);

alter table public.guest_access_tokens enable row level security;
alter table public.guest_documents enable row level security;
alter table public.document_reviews enable row level security;
alter table public.document_access_events enable row level security;
create policy tokens_select on public.guest_access_tokens for select to authenticated using (private.has_permission(property_id, 'guest_requests.manage'));
create policy docs_select on public.guest_documents for select to authenticated using (private.has_permission(property_id, 'documents.review'));
create policy reviews_select on public.document_reviews for select to authenticated using (private.has_permission(property_id, 'documents.review'));
create policy doc_access_select on public.document_access_events for select to authenticated using (private.has_permission(property_id, 'documents.review'));

-- Private bucket; no storage.objects policies exist, so only service-role signed URLs can touch files.
do $$ begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('guest-documents', 'guest-documents', false, 10485760, array['image/jpeg', 'image/png', 'application/pdf'])
    on conflict (id) do nothing;
  end if;
end $$;

-- ---------- order creation refactor: shared core so the portal can order without a staff identity ----------
create function private.place_order_core(
  p_property uuid, p_kind text, p_items jsonb, p_reservation uuid, p_table text, p_notes text, p_actor uuid
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_tenant uuid; v_res public.reservations; v_unit uuid; v_id uuid;
  v_sub numeric := 0; v_tax numeric := 0; v_count int := 0; rec record;
begin
  select tenant_id into v_tenant from public.properties where id = p_property;
  if v_tenant is null then raise exception 'unknown property' using errcode = '22023'; end if;
  if p_kind not in ('restaurant', 'room_service') then raise exception 'invalid order kind' using errcode = '22023'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'order needs at least one item' using errcode = '22023'; end if;
  if p_reservation is not null then
    select * into v_res from public.reservations where id = p_reservation and property_id = p_property;
    if not found or v_res.status <> 'checked_in' then raise exception 'reservation must be checked in' using errcode = '22023'; end if;
    select unit_id into v_unit from public.unit_holds where reservation_id = p_reservation and active limit 1;
  elsif p_kind = 'room_service' then
    raise exception 'room service needs a reservation' using errcode = '22023';
  end if;

  insert into public.orders (tenant_id, property_id, kind, reservation_id, unit_id, table_label, notes, placed_by)
  values (v_tenant, p_property, p_kind, p_reservation, v_unit, p_table, p_notes, p_actor) returning id into v_id;

  for rec in
    select mi.id, mi.name, mi.price, mi.tax_rate_percent, x.quantity
    from jsonb_to_recordset(p_items) as x(menu_item_id uuid, quantity int)
    join public.menu_items mi on mi.id = x.menu_item_id and mi.property_id = p_property and mi.active
  loop
    if rec.quantity is null or rec.quantity < 1 or rec.quantity > 50 then raise exception 'invalid quantity' using errcode = '22023'; end if;
    insert into public.order_items (tenant_id, property_id, order_id, menu_item_id, name_snapshot, unit_price, tax_rate_percent, quantity)
    values (v_tenant, p_property, v_id, rec.id, rec.name, rec.price, rec.tax_rate_percent, rec.quantity);
    v_sub := v_sub + rec.price * rec.quantity;
    v_tax := v_tax + round(rec.price * rec.quantity * rec.tax_rate_percent / 100, 2);
    v_count := v_count + 1;
  end loop;
  if v_count <> jsonb_array_length(p_items) then raise exception 'unknown or inactive menu item' using errcode = '22023'; end if;

  update public.orders set subtotal = v_sub, tax = v_tax, total = v_sub + v_tax where id = v_id;
  insert into public.kitchen_events (tenant_id, property_id, order_id, event_type, actor_id) values (v_tenant, p_property, v_id, 'placed', p_actor);
  return v_id;
end $$;
revoke all on function private.place_order_core(uuid, text, jsonb, uuid, text, text, uuid) from public, anon, authenticated;

create or replace function public.place_order(
  p_property uuid, p_kind text, p_items jsonb, p_reservation uuid default null, p_table text default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  if not private.has_permission(p_property, 'orders.place') then raise exception 'not permitted' using errcode = '42501'; end if;
  return private.place_order_core(p_property, p_kind, p_items, p_reservation, p_table, p_notes, auth.uid());
end $$;

-- ---------- staff: portal links ----------
create function public.create_guest_portal_link(p_reservation uuid, p_ttl_hours int default 168) returns text
language plpgsql security definer set search_path = '' as $$
declare r public.reservations; v_token text; v_exp timestamptz;
begin
  select * into r from public.reservations where id = p_reservation;
  if not found or not private.has_permission(r.property_id, 'guest_requests.manage') then raise exception 'not permitted' using errcode = '42501'; end if;
  if r.status not in ('confirmed', 'checked_in') then raise exception 'reservation is not active' using errcode = '22023'; end if;
  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');          -- 244 random bits, 64 hex chars
  v_exp := least(now() + make_interval(hours => greatest(1, least(p_ttl_hours, 720))), (r.check_out + 3)::timestamptz);
  insert into public.guest_access_tokens (tenant_id, property_id, reservation_id, token_hash, expires_at, created_by)
  values (r.tenant_id, r.property_id, r.id, encode(sha256(convert_to(v_token, 'utf8')), 'hex'), v_exp, auth.uid());
  return v_token;                                   -- shown once; only the hash is kept
end $$;

create function public.revoke_guest_portal_link(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare t public.guest_access_tokens;
begin
  select * into t from public.guest_access_tokens where id = p_id;
  if not found or not private.has_permission(t.property_id, 'guest_requests.manage') then raise exception 'not permitted' using errcode = '42501'; end if;
  update public.guest_access_tokens set revoked_at = now() where id = p_id and revoked_at is null;
end $$;

-- ---------- portal: everything is derived from the token, never from client-supplied ids ----------
create function private.portal_reservation(p_token text) returns public.reservations
language plpgsql security definer set search_path = '' as $$
declare t public.guest_access_tokens; r public.reservations;
begin
  select * into t from public.guest_access_tokens where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'utf8')), 'hex');
  if not found or t.revoked_at is not null or t.expires_at < now() then
    raise exception 'invalid or expired link' using errcode = '28000';
  end if;
  update public.guest_access_tokens set last_used_at = now(), use_count = use_count + 1 where id = t.id;
  select * into r from public.reservations where id = t.reservation_id;
  return r;
end $$;
revoke all on function private.portal_reservation(text) from public, anon, authenticated;

create function public.portal_get_stay(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r public.reservations; v jsonb;
begin
  r := private.portal_reservation(p_token);
  select jsonb_build_object(
    'stay', jsonb_build_object('check_in', r.check_in, 'check_out', r.check_out, 'status', r.status, 'adults', r.adults, 'children', r.children),
    'property', (select jsonb_build_object('name', p.name, 'timezone', p.timezone) from public.properties p where p.id = r.property_id),
    'guest_name', (select g.full_name from public.guests g where g.id = r.guest_id),
    'unit', (select u.name from public.unit_holds h join public.accommodation_units u on u.id = h.unit_id where h.reservation_id = r.id and h.active limit 1),
    'services', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name) from public.service_catalog s where s.property_id = r.property_id and s.active), '[]'),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'title', q.title, 'status', q.status, 'created_at', q.created_at,
                  'rated', exists (select 1 from public.guest_request_feedback f where f.guest_request_id = q.id)) order by q.created_at desc)
                  from public.guest_requests q where q.reservation_id = r.id), '[]'),
    'menu', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'price', m.price, 'tax_rate_percent', m.tax_rate_percent) order by m.name)
                  from public.menu_items m where m.property_id = r.property_id and m.active), '[]'),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'doc_type', d.doc_type, 'status', d.status) order by d.created_at)
                  from public.guest_documents d where d.reservation_id = r.id), '[]')
  ) into v;
  return v;
end $$;

create function public.portal_create_request(p_token text, p_catalog uuid default null, p_title text default null, p_notes text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r public.reservations;
begin
  r := private.portal_reservation(p_token);
  if length(coalesce(p_title, '')) > 200 or length(coalesce(p_notes, '')) > 1000 then raise exception 'text too long' using errcode = '22023'; end if;
  if (select count(*) from public.guest_requests where reservation_id = r.id and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'too many requests, please try again later' using errcode = '54000';
  end if;
  return private.create_guest_request_core(r.property_id, r.id, p_catalog, p_title, p_notes, 'portal', null);
end $$;

create function public.portal_place_order(p_token text, p_items jsonb, p_notes text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r public.reservations;
begin
  r := private.portal_reservation(p_token);
  if length(coalesce(p_notes, '')) > 500 then raise exception 'text too long' using errcode = '22023'; end if;
  if (select count(*) from public.orders where reservation_id = r.id and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'too many orders, please try again later' using errcode = '54000';
  end if;
  return private.place_order_core(r.property_id, 'room_service', p_items, r.id, null, p_notes, null);
end $$;

create function public.portal_submit_feedback(p_token text, p_request uuid, p_rating int, p_comment text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.reservations; q public.guest_requests;
begin
  r := private.portal_reservation(p_token);
  select * into q from public.guest_requests where id = p_request and reservation_id = r.id;   -- scoped to this stay
  if not found then raise exception 'request not found' using errcode = '22023'; end if;
  if q.status <> 'completed' then raise exception 'feedback is only collected for completed requests' using errcode = '22023'; end if;
  insert into public.guest_request_feedback (tenant_id, property_id, guest_request_id, rating, comment)
  values (q.tenant_id, q.property_id, q.id, p_rating, left(p_comment, 1000));
end $$;

-- ---------- documents: prepare/confirm/scan are service_role only (edge functions + scanner) ----------
create function public.portal_prepare_document(p_token text, p_doc_type text, p_mime text, p_size int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r public.reservations; v_id uuid := gen_random_uuid(); v_path text;
begin
  r := private.portal_reservation(p_token);
  if p_mime not in ('image/jpeg', 'image/png', 'application/pdf') then raise exception 'unsupported file type' using errcode = '22023'; end if;
  if p_size is null or p_size < 1 or p_size > 10485760 then raise exception 'file size must be between 1 byte and 10 MB' using errcode = '22023'; end if;
  if (select count(*) from public.guest_documents where reservation_id = r.id) >= 10 then raise exception 'document limit reached' using errcode = '54000'; end if;
  v_path := r.tenant_id || '/' || r.property_id || '/' || r.id || '/' || v_id;
  insert into public.guest_documents (id, tenant_id, property_id, reservation_id, guest_id, doc_type, storage_path, mime_type, size_bytes)
  values (v_id, r.tenant_id, r.property_id, r.id, r.guest_id, p_doc_type, v_path, p_mime, p_size);
  return jsonb_build_object('document_id', v_id, 'storage_path', v_path);
end $$;

create function public.portal_confirm_document(p_token text, p_doc uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.reservations;
begin
  r := private.portal_reservation(p_token);
  update public.guest_documents set status = 'uploaded', uploaded_at = now()
   where id = p_doc and reservation_id = r.id and status = 'pending_upload';
  if not found then raise exception 'document not found' using errcode = '22023'; end if;
end $$;

create function public.mark_document_scan(p_doc uuid, p_result text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_result not in ('clean', 'infected') then raise exception 'invalid scan result' using errcode = '22023'; end if;
  update public.guest_documents set status = p_result, scanned_at = now() where id = p_doc and status = 'uploaded';
  if not found then raise exception 'document is not awaiting a scan' using errcode = '22023'; end if;
end $$;

-- ---------- staff: audited access and review ----------
create function public.authorize_document_access(p_doc uuid, p_reason text) returns text
language plpgsql security definer set search_path = '' as $$
declare d public.guest_documents;
begin
  select * into d from public.guest_documents where id = p_doc;
  if not found or not private.has_permission(d.property_id, 'documents.review') then raise exception 'not permitted' using errcode = '42501'; end if;
  if d.status not in ('clean', 'approved', 'rejected') then raise exception 'document is not available (status %)', d.status using errcode = '22023'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '22023'; end if;
  insert into public.document_access_events (tenant_id, property_id, document_id, accessed_by, reason)
  values (d.tenant_id, d.property_id, d.id, auth.uid(), p_reason);
  return d.storage_path;      -- the edge function signs a short-lived URL for this path
end $$;

create function public.review_document(p_doc uuid, p_decision text, p_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare d public.guest_documents;
begin
  select * into d from public.guest_documents where id = p_doc for update;
  if not found or not private.has_permission(d.property_id, 'documents.review') then raise exception 'not permitted' using errcode = '42501'; end if;
  if d.status <> 'clean' then raise exception 'only scanned-clean documents can be reviewed' using errcode = '22023'; end if;
  insert into public.document_reviews (tenant_id, property_id, document_id, decision, note, reviewed_by)
  values (d.tenant_id, d.property_id, d.id, p_decision, p_note, auth.uid());
  update public.guest_documents set status = p_decision where id = p_doc;
end $$;

revoke execute on function
  public.create_guest_portal_link(uuid, int), public.revoke_guest_portal_link(uuid), public.portal_get_stay(text),
  public.portal_create_request(text, uuid, text, text), public.portal_place_order(text, jsonb, text),
  public.portal_submit_feedback(text, uuid, int, text), public.portal_prepare_document(text, text, text, int),
  public.portal_confirm_document(text, uuid), public.mark_document_scan(uuid, text),
  public.authorize_document_access(uuid, text), public.review_document(uuid, text, text) from public, anon, authenticated;
grant execute on function public.portal_get_stay(text), public.portal_create_request(text, uuid, text, text),
  public.portal_place_order(text, jsonb, text), public.portal_submit_feedback(text, uuid, int, text) to anon, authenticated;
grant execute on function public.portal_prepare_document(text, text, text, int), public.portal_confirm_document(text, uuid),
  public.mark_document_scan(uuid, text) to service_role;
grant execute on function public.create_guest_portal_link(uuid, int), public.revoke_guest_portal_link(uuid),
  public.authorize_document_access(uuid, text), public.review_document(uuid, text, text) to authenticated;
