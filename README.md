# Hospitality Operations & Distribution Platform

Implements `Hospitality_SaaS_Development_Specification_v1.md`. Working title TBD.

Deploy the staff app and guest portal using [the Vercel deployment guide](docs/vercel-deployment.md). Database migrations, Supabase Edge Functions, and persistent workers are deployed separately.

## Status
- [x] Milestone 1 (in progress): monorepo layout, Supabase migration for tenancy + RBAC + RLS, pgTAP RLS tests, CI
- [x] Hardening migration: IANA timezone validation, last-owner protection (tests in 002)
- [~] Milestone 2 (in progress): `apps/web` with Supabase auth, middleware guard, onboarding (tenant + first property), dashboard.

Android staff app: see `apps/android/README.md`.

## Run locally
See `docs/local-development.md` (Supabase start, tests, demo seed, apps, workers).

## What exists
- `supabase/migrations/20261105000001_tenancy_rbac.sql`: profiles, tenants, properties, tenant/property memberships, roles/permissions, helpers in the non-exposed `private` schema, RLS on every table, `create_tenant()` onboarding RPC, seeded system roles.
- `supabase/tests/001_tenancy_rls.test.sql`: isolation and permission tests.
- `packages/permissions`: permission keys shared with clients (UI hints only).
- `supabase/tests/999_security_audit.test.sql`: fails the build if a table lacks RLS, a SECURITY DEFINER function lacks a pinned search_path, or a function is exposed to the wrong role.

## Conventions
- Identity is always `auth.uid()`; clients never send tenant IDs for authorization.
- Every tenant-owned table: `tenant_id`, composite FK `(parent_id, tenant_id)`, RLS enabled, policies via `private.*` helpers.
- Timestamps UTC; property timezone is IANA. Money is `numeric`.

## Platform admin
Grant yourself access locally (SQL editor / psql, as superuser):
```sql
insert into public.platform_admins (user_id) select id from auth.users where email = 'you@example.com';
```
Then open `/admin`. Platform admins land here after sign-in. Use the hotel directory to find a business, add hotels, review owner contacts and setup counts, change plans, or suspend/reactivate the business. New-business setup requires an existing verified owner account. Platform access exposes hotel identity and setup metadata; guest records, reservations, inbox conversations and hotel payments remain scoped to hotel users. See [platform administration](docs/local-development.md#platform-administration) for setup and access behavior.

## Reservations (milestone 3, part 1)
- `unit_holds` has an exclusion constraint (`unit_id` + overlapping `daterange`) so double-booking is impossible at the database level. Holds cover both reservations and inventory blocks.
- Writes to reservations go through `create_reservation`, `cancel_reservation`, `check_in_reservation`, `check_out_reservation`, `create_inventory_block`. `availability()` is read-only and respects RLS.
- Race test: `./supabase/tests/concurrency.sh` (needs `psql`).

## Web screens (milestone 3, part 2)
`/p/<propertyId>/inventory` (types, units, blocks) and `/p/<propertyId>/reservations` (14-day occupancy grid, new booking, check-in/out, cancel). All writes use RLS or the reservation functions; the UI never sends authorization data.

## Staff tasks and housekeeping (milestone 4)
- Tasks are internal work items; guest requests will be a separate table linked by `guest_request_id`. Managers (`tasks.assign`) see all tasks; other staff see their own plus unassigned ones they can claim.
- Checkout creates one housekeeping task per unit (deduplicated). Starting it sets the unit `in_progress`, finishing it sets `clean`. Inspection as a separate step is not modelled yet.
- Writes go through `create_task`, `assign_task`, `claim_task`, `set_task_status`; comments are plain RLS inserts.
- UI: `/p/<propertyId>/tasks`.

## Guest services (milestone 5)
- Guest requests are separate from tasks and linked via `tasks.guest_request_id`. A routing rule per service creates the linked task (kind, default assignee, SLA).
- Request status follows its task (trigger); cancelling a request cancels its open task; requests without a task are completed by front desk.
- `private.create_guest_request_core` is the single entry point and is callable only by `service_role`, ready for the guest-portal and WhatsApp edge functions (milestones 8-9). Staff use `create_guest_request`.
- Not yet: notifying the guest on completion and collecting feedback from the guest (needs WhatsApp/portal); order routing (milestone 7).
- UI: `/p/<propertyId>/requests`.

## Android staff app (milestone 6, first slice)
`apps/android`: Compose app using supabase-kt (Auth + Postgrest). Tasks and rooms only so far; the app holds just the anon key.

## Restaurant, folios, payments, night audit (milestone 7)
- Orders (restaurant / room service) snapshot menu prices and tax; serving a room-service order posts it to the stay's folio. Walk-in restaurant orders are paid directly (`collect_order_payment`). Orders and payments are separate tables.
- Folio = append-only ledger (room nights, orders, adjustments). Payments store a method and opaque reference only (never card data). Refunds need `finance.write`; credits/discounts too.
- `check_out_reservation` now posts any unposted nights and refuses checkout unless the folio balance is zero. `finalize_invoice` numbers the invoice (`INV-YYYY-000001`, per-property counter) and closes the folio.
- `run_night_audit(property, date)` posts room nights for in-house guests (idempotent), reports no-show candidates, refuses future dates.
- New permissions: `billing.manage` (front desk, manager, accountant), `orders.place` (front desk, manager).
- Deferred: cash sessions, expenses, GST-compliant invoice series and tax breakup (confirm with counsel), early-checkout charge policy, payment gateway integration.
- UI: `/p/<id>/orders`, `/p/<id>/billing`.

## Verification status
Migrations 0001-0008 apply cleanly on PostgreSQL 16 and all pgTAP suites (251 assertions) plus `concurrency.sh` pass against a plain-Postgres stub of Supabase's `auth` schema and roles. The Next.js app and Android app have not been compiled yet.

## WhatsApp (milestone 8, backend)
Tables, inbound/outbound functions, consent, 24h-window rules, durable outbound queue with retry/dead-letter, webhook edge function and worker. See `docs/whatsapp.md`. Web inbox: `/p/<id>/inbox`. Meta test-number inbound messages and Inbox replies have been verified. Hotel Cloud API Embedded Signup is implemented at `/p/<id>/whatsapp`; its HTTPS configuration, Meta approvals and live signup test remain prerequisites. See [hotel onboarding setup](docs/whatsapp-onboarding.md).

## Guest portal and documents

The guest app provides a mobile stay hub, arrival details, document uploads/status, a dining cart, tracked service requests, a bill view and an installable shell. Personal data is never cached offline. Guest assistance requests leave check-in/out confirmation with hotel staff. See [guest portal setup](docs/guest-portal.md).
Signed, expiring, revocable per-stay links; `apps/guest-portal` (requests, room-service orders, feedback, document upload); token-scoped `portal_*` functions; documents with size/type limits, scan gate, review and access audit; two edge functions. Staff generate links from the Reservations page. Details and open items: `docs/guest-portal.md`. Not built: the malware scanner, retention/deletion jobs, portal notifications.

## Staff management
`/t/<tenantId>/team`: invite by email with per-property roles, pending invitations, per-property role checkboxes, owner/admin/member roles, removal. Invitations are accepted automatically (`accept_staff_invitations`, called on dashboard load) when the invited person signs up with that exact, confirmed email. Nothing is emailed: the inviter tells them to sign up. Only owners/admins can invite or assign; the last owner cannot be removed or demoted. Locally, Supabase auto-confirms emails when confirmations are disabled; with confirmations on, the invitee must confirm first.

## Channel manager (milestone 10)
Channel setup for Agoda, Booking.com and MakeMyTrip; Agoda sandbox product, nightly-rate and limited reservation workflows plus Booking.com availability-only sandbox adapters with OAuth, paused setup and operator approval, room mapping and leased sync jobs. Mock reservation ingestion remains available for tests; automatic import is limited to single-room Agoda Property Collect bookings; other providers, group/settlement workflows, reconciliation and certification are pending. No OTA is live. Worker: `services/channel-manager`; UI: `/p/<id>/channels`. See `docs/channel-manager.md` for official sources, setup and access requirements.

## Hardening round
Private-schema lockdown migration; security-audit test; lockfiles per app (`npm ci`); CI for database, web, portal, both workers and edge functions (`.github/workflows/ci.yml`); local `config.toml` with function JWT settings; demo seed script; `docs/local-development.md`. Edge functions now type-check under Deno 2.

### Hotel marketing campaigns

Guest audiences, manual recipient selection, campaign drafts, one-off hotel-timezone scheduling, cancellation and per-recipient WhatsApp delivery reporting are available in the local implementation at `/p/<id>/campaigns`. Delivery requires an active hotel sender, verified approved text-only marketing template, recorded permission and an explicitly enabled worker; no campaign sending is enabled by default. See [docs/whatsapp-campaigns.md](docs/whatsapp-campaigns.md).
