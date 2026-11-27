# Local development

**Prerequisites:** Docker, Supabase CLI, Node 22, `psql` (for the race test). Android Studio only for the staff app.

## 1. Database and auth
```bash
supabase start                 # applies all migrations (13 so far); prints API URL and keys
supabase test db               # 250+ pgTAP assertions: RLS, permissions, workflows, security audit
npm run db:race                # 12 parallel bookings against 3 rooms; expects exactly 3 to succeed
eval "$(supabase status -o env | sed 's/^/export /')"
```

## 2. Demo data (also a smoke test of the real API paths)
```bash
cd scripts && npm ci && cd ..
SUPABASE_URL=$API_URL SUPABASE_ANON_KEY=$ANON_KEY SUPABASE_SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY npm run seed
```
Creates `owner@`, `frontdesk@`, `housekeeping@`, `kitchen@demo.test` (password printed), a hotel with 6 rooms, menu, services, one in-house guest and one future booking. The service-role key is used only by this script.

## 3. Apps
```bash
# staff web app  http://localhost:3000
cd apps/web && cp .env.example .env.local        # set NEXT_PUBLIC_SUPABASE_ANON_KEY=$ANON_KEY
npm ci && npm run dev

# guest portal   http://localhost:3001
cd apps/guest-portal && cp .env.example .env.local && npm ci && npm run dev
```
Sign in as `owner@demo.test`. To generate a guest link: Reservations page -> **Guest link** on an in-house stay. Platform admin: `insert into public.platform_admins select id from auth.users where email='owner@demo.test';` then open `/admin`.

## 4. Workers and functions (optional locally)
- Channel manager worker (mock provider): `SUPABASE_URL=$API_URL SUPABASE_SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY npm start` in `services/channel-manager` after `npm run build`. Map a room type on the Channels page, book a room, watch the mock availability table update.
- Notification worker + `whatsapp-webhook` need Meta credentials; see `docs/whatsapp.md`. `supabase functions serve` runs the edge functions locally.
- Guest documents need a malware scanner before staff can open uploads (`docs/guest-portal.md`).

## 5. Android
Open `apps/android` in Android Studio, copy `local.properties.example` to `local.properties`, add the anon key, run on an emulator. Never compiled yet; expect to adjust library versions.

## Checks the CI runs
Database suites + race test, type-check and build for web and portal, type-check for both workers, `deno check` for edge functions. Android is not in CI yet.

## Known first-run risks (never executed against a real stack)
The seed script, GoTrue email-confirmation behaviour with invitations, the Supabase Storage signed-upload flow, Meta's real payloads, and the Android app. The SQL layer is the most tested part; start any debugging at the edges.

## Web authentication

The web app provides `/login`, `/signup`, `/forgot-password`, and `/reset-password`.
Set `APP_URL` in `apps/web/.env.local` to the trusted public origin (locally,
`http://localhost:3000`). Email confirmations and recovery return through
`/auth/confirm`, which exchanges the PKCE code for a server session. Token-hash
email links are also supported with `token_hash` and `type` query parameters.
When deploying, configure Supabase Auth's site URL and redirect allow-list for
that origin and callback route, including its query string. Keep email
confirmation enabled for production. The local config permits this callback;
restart the local Supabase stack after changing auth configuration.

New accounts require a 12-character password containing uppercase and lowercase
letters and a number or symbol. Existing accounts retain their current sign-in
passwords. Invited staff should use the exact invitation email. Invitation
acceptance remains on dashboard load after email verification.

For local email testing, use the mail inbox URL printed by `supabase status`.
Verify signup with confirmations enabled, confirmation resend, expired links,
and password recovery in the same browser that requested the email (PKCE).
Run redirect and validation regression checks with `npm run test:auth` from
`apps/web`.

## Advanced reservations

The Reservations workspace provides paginated guest/reference search, status and
source filters, overlapping stay-date filters, archive views, and a 14-night
calendar with room pagination. Open a guest or calendar booking for its detail
page. Dashboard booking shortcuts point to these same routes.

New reservations use a live quote and one database transaction for the guest,
reservation, and room hold. Request IDs protect retries. Room selection is
optional; the database allocates an available room when omitted. Failed edits
roll back the original allocation. Version checks prevent stale stay changes.

Confirmed direct/walk-in stays can be repriced and edited before financial
activity. In-house guests can move between rooms of the same type. Stay actions
include check-in/out, reasoned cancellation/no-show, room-night posting, internal
notes, and guest portal link generation. Check-in requires a clean, active,
unoccupied room within the booked dates. In-house moves create a cleaning task
for the old room. Checkout retains the existing full-booked-stay charging policy
and requires a zero balance; payments are handled in Billing. Channel bookings
must be changed/cancelled through their channel. No-show actions do not transmit
provider updates or calculate fees. In-house date extensions, group/multi-room
bookings, and automatic cancellation/no-show fee policies are not included.

Run `npm run test:reservations` in `apps/web` for date/filter checks and
`supabase test db supabase/tests/014_advanced_reservations.test.sql` for booking,
allocation, rollback, status, settlement, pagination, and permission regressions.

## Billing and folios

Billing now provides paginated folio search, posted-balance filters, guest and
payment history, a chronological ledger with running balances, and exact-decimal
CSV export. In-house stays appear before any folio is created; merely viewing a
folio does not create financial records. Open a guest from Billing for the ledger
and transaction forms. Finance readers can inspect billing without receiving
reservation-edit permissions.

Payment, adjustment, refund, and invoice requests carry an idempotency key and
check the balance presented by the form. Deposits/overpayments require explicit
confirmation. Card/UPI/bank-transfer records require a transaction reference, and
the web workflow rejects a reference already recorded for that method/property.
These are manual accounting records: the app does not charge cards or transfer
payments/refunds through a gateway. Credits and refunds require `finance.write`;
recording payments, adding charges, invoicing, and auditing require
`billing.manage`.

Invoice issuance posts remaining booked room nights, requires zero balance and
no pending room orders, and snapshots hotel identity, guest identity, and charge
lines. Later changes to property/guest details do not rewrite that document.
Post-invoice refunds issue a matching separate credit note so the original
invoice remains unchanged and the closed folio stays balanced. Open-folio
refunds increase the posted balance; any reduction of charges is recorded as a
separate credit. Printed invoices/credit notes and CSV downloads stay scoped to
the signed-in user's property access. Legacy invoices without snapshots are
explicitly identified in the document view. Tax calculation/series compliance
and payment-gateway integration are not implemented by these screens.

Night audits retain per-run history and cumulative posted amounts for each
business date. Repeating the same request does not create another run; a new
run posts only missing room nights. The hotel timezone determines the maximum
business date. No-show candidates are reported for staff review, not changed.

Run `npm run test:billing` in `apps/web`,
`supabase test db supabase/tests/016_advanced_billing.test.sql`, and
`python3 supabase/tests/billing-concurrency.py`. The concurrency test uses an
isolated temporary business and generated account, verifies payment/invoice
retry and refund/charge races, and removes its financial fixtures in dependency
order. It never processes real payments or refunds.

### Guest service desk

Open **Guest requests** in the hotel workspace for searchable, paginated queues,
priority and response-target indicators, and request details with linked work,
internal comments, feedback provenance, and request/task history. New requests
select an active guest stay; configured services create their linked task
atomically. Managers configure categories, descriptions, default priority,
response targets, departments and eligible assignees under **Service catalog**.
Deactivating a service preserves history and prevents new requests for it;
configuration edits apply only to future requests.

Front desk can triage and manage requests, but completing routed work requires
task-management permission or the assigned worker's task-write permission.
Housekeeping sees requests linked to its own assigned tasks, including scoped
queue counts. Guest-service tasks never mark rooms clean. Cancellation and task
completion share a request lock to keep their final statuses consistent. Ratings
recorded by staff are labeled separately from guest-portal submissions; requests
with feedback cannot be reopened (create a follow-up instead).

Response targets are displayed in the hotel's timezone. Indicators do not send
automatic escalation, WhatsApp, or email messages. Comments are internal.
Migrations 27–29 implement the service desk. Verify using the transactional
`017_advanced_requests.test.sql` suite, `npm run test:service-desk` in `apps/web`,
and `python3 supabase/tests/service-concurrency.py` against local Supabase.

### Tasks and housekeeping

Open **Tasks** for the operational queue, then switch to **Room readiness** for
cleanliness, in-house occupancy indicators, and today's arrivals that need care.
Queue filters cover ownership, work type, priority, overdue work and history;
matching counts cover all records, with 20 tasks or 12 rooms per page.
Dashboard task cards and guest-service requests link to the task detail view.

Task managers create work with instructions, an optional room/department,
eligible assignee, a target up to one week away, and up to 20 completion steps.
The standard cleaning checklist is an editable starting point on the creation
form. Existing and automatically created checkout tasks retain their existing
checklist (which may be empty); managers can add steps from task details.
Assigned workers can check steps and add internal handover notes. Checklist
structure is managed separately by task managers. Every configured step must be
checked before completion, including through the legacy status RPC.

Room-linked housekeeping moves the room from dirty to in progress to clean.
Cancellation leaves it dirty; reopening resets its checklist and marks it dirty.
Cleanliness does not imply that a room is vacant, unblocked or available to book.
Guest-service tasks remain separate from room cleaning. Reopening linked service
work may be blocked when guest feedback already exists.

Task managers oversee all hotel tasks. Other staff see their own assigned work;
browsing unassigned work requires both `tasks.read` and `tasks.write`. Staff must
claim unassigned work before updating progress. Read-only front desk staff can
use room readiness without browsing unassigned task details. Room cards show
only a task link when that task is visible to the current staff member.

Migrations 30–33 add versioned, idempotent task commands, scoped read models,
checklist enforcement and consistent room/task lock ordering. Targets do not
send escalation notifications; comments remain internal. Verify with
`018_advanced_tasks.test.sql`, `npm run test:tasks` in `apps/web`, and
`python3 supabase/tests/task-concurrency.py` against local Supabase. The race
script uses a temporary tenant and removes its own fixtures afterward.

### Rooms and inventory

Open **Rooms & inventory** for searchable, paginated directories of rooms,
room types, availability blocks, and rate plans. Room settings include type,
floor/wing, internal notes and active status. New rooms created here start dirty;
use Tasks & housekeeping to prepare them for check-in. Deactivation and type
changes are blocked while the room has upcoming/current holds, an in-house guest,
or open room tasks. Reducing type capacity also checks upcoming/in-house guests.

Room types configure accommodation kind, capacity and base nightly price. Rate
plans apply a percentage adjustment to that base on new quotes; this screen does
not configure tax rules, cancellation policies, stay restrictions, or OTA pricing.
Changing prices preserves recorded booking totals and posted financial history.
Confirmed-stay edits that request a new quote use the current configuration.

Availability blocks cover nights from the start date up to (excluding) the end
date. New blocks require 1–365 nights starting today or later and a reason.
Database constraints reject overlaps with existing holds. Release a block from
its details with a reason; its original dates and history remain. Release does
not mark a room clean or close maintenance tasks. Existing legacy blocks may
have no recorded reason. Room detail shows up to 20 current/upcoming holds and
links to reservations when the staff member also has reservation-read access.

Inventory configuration and history require `inventory.manage`. Migrations
34–36 add versioned/idempotent commands, audit events, room-allocation locks and
scoped read models. Housekeeping-only status changes increment room versions
but stay in task history rather than cluttering inventory configuration history.
Pre-migration configuration changes have no backfilled audit trail.

Verify with `019_advanced_inventory.test.sql`, `npm run test:inventory` inside
`apps/web`, and `python3 supabase/tests/inventory-concurrency.py`. The local race
check creates and removes its own tenant and covers booking versus deactivation,
room-type reassignment, capacity reduction, duplicate block submissions, and
12 competing bookings for three rooms.

### Orders and room service

Open **Orders** for filtered, paginated order queues or the kitchen board. The
board shows only the current page (up to 20 matching orders), with explicit
pagination. New-order carts support walk-in restaurant orders, room service,
and restaurant orders charged to an in-house guest. Search in-house stays by
name, room or reservation ID. Invoiced folios are excluded. Up to 30 distinct
menu lines are allowed, with quantities 1–50. Tax rounds per line using exact
decimal arithmetic; staff must review the current menu version and total before
placement. Duplicate submission keys return the original order.

Menu managers configure categories, descriptions, dietary notes, prices, tax,
availability and optional preparation targets. Existing orders retain recorded
names, prices and taxes. New orders use the longest selected preparation target
unless overridden. Targets are indicators; they do not send notifications.
Staff-only handover comments are separate from order instructions and are not
exposed through the guest portal.

Kitchen access (`orders.write`) advances placed → preparing → ready → served.
Placement access permits early cancellation, with a reason in the new interface;
ready and served orders cannot be cancelled through that workflow. Serving a
room-charged order posts its charge once to the open folio. The detail page shows
current/latest room context when a guest has moved. Kitchen readers do not get
payment/refund records, financial queue counts, or restricted guest profiles.
Finance/billing staff can access the order workspace for their financial actions.

Served walk-in orders can have a received payment recorded by billing staff;
complimentary orders have no payment due. Finance-write access is needed to
record refunds against the remaining original payment amount. Payment and refund
forms record financial activity; they do not contact payment providers. Room
charges are reviewed and settled in Billing. Partial/direct-order refunds do not
reopen the order for a second payment.

Migrations 37–41 add menu/order versions, idempotent commands, internal comments,
scoped read models and reservation → folio → order locking for room orders.
Stage timestamps are recovered from existing kitchen events where available.
Verify with `020_advanced_orders.test.sql`, `npm run test:orders` in `apps/web`,
and `python3 supabase/tests/order-concurrency.py`. Race checks create and remove
an isolated tenant and cover duplicate orders/payments, competing refunds,
concurrent menu edits, duplicate serving, and serving versus invoice finalization.

### Team and access

Open **Team & access** for the business-wide staff directory, invitation queue,
and access history. Search members by name/email, filter by business role or
hotel, and paginate 20 records at a time. The active hotel in the sidebar is
navigation context; it does not implicitly filter the business directory.
Member detail shows per-hotel roles, effective permission unions, and direct
links to up to five assigned tasks/conversations, with full assignment counts.

Owners and business administrators have full access across current and future
properties. Property-based staff receive the combined permissions of their
hotel roles. Only owners manage business roles, invite administrators, or remove
administrators/owners. The business must retain an owner, including concurrent
owner changes. Hotel-level `staff.manage` does not grant business administration.
Existing custom roles can be assigned and previewed; this feature does not edit
role definitions. Ambiguous role keys cannot be assigned by the guarded APIs.

Invitations require a matching confirmed account and are accepted when that
account opens the dashboard. Invitations never promote an existing business
membership. The new UI lets administrators choose 1–30 days of validity, review
specific hotel roles, renew pending/expired invitations, revoke with a reason,
and copy signup/login instructions. Nothing is emailed or messaged automatically.
Accepted and revoked invitations remain as history. An accepted invitation does
not link to a member page after that membership has been removed.

Access changes require reasons and current member/invitation versions. Business
role/removal forms additionally confirm the displayed person. Reassign or resolve
open tasks and conversations before removing the permissions they need. Update
default service routing before withdrawing task-work permission. Reopening older
closed work releases an assignee who no longer has the required access. Business
removal preserves accounts and historical operational/financial records; it also
revokes pending invitations issued by or addressed to the removed person. An
administrator demoted to property-based staff has their pending delegations revoked.

Migrations 42–48 add administrator-only read models, staff command idempotency,
version checks, audit history, last-owner serialization and shared assignment
locks. Membership, property-membership and user-role writes now use guarded RPCs
rather than direct authenticated table writes; existing staff RPCs remain supported.
History begins with these migrations, without fabricating older events. Verify
with `021_advanced_team.test.sql`, `npm run test:team` in `apps/web`, and
`python3 supabase/tests/team-concurrency.py`. Race tests create and remove their
own business and cover owner demotion, acceptance/revocation, task claiming,
default routing versus access removal, and duplicate invitations.

### Property settings and operational defaults

Open **Property settings** for the hotel overview, identity/contact details,
timezone/currency, guest experience, operational defaults and paginated change
history. Only business owners/administrators edit these settings. Reviewed
updates require a reason, property/settings versions and an idempotency key.
Timezone changes require an acknowledgement of the local-day impact. Currency
is locked after bookings/orders/payments exist; earlier currency changes keep
configured room/menu price numbers and require explicit review, without conversion.
Issued invoice snapshots and recorded operational dates stay as recorded.

Standard arrival/departure times and guest-facing arrival/stay information are
shown in reservation details and the token-scoped guest portal, together with
current hotel contact/address information. Standard times are informational:
no new hourly check-in/out enforcement or change to date-range allocation is
introduced. Guest-facing text reflects current hotel settings; private operations
settings, checklists and history are excluded from guest responses.

Booking nights, adult count and rate plan seed new manual reservation forms.
The initial adult count is limited to the selected room type's capacity. Staff
still request an availability/price quote and may adjust the stay. Existing
bookings and portal/channel booking behavior are retained. New web bookings and
orders submit the reviewed currency, so stale forms cannot silently place the
same numeric amount in a newly selected hotel currency.

Turnaround-cleaning priority, target and checklist are copied into new room-linked
checkout/room-move tasks; existing work stays unchanged. Room-preset task creation
forms receive these preferences for review. The standard cleaning checklist can
be applied explicitly. All configured steps must be checked before completion.
Empty templates create no mandatory auto-turnaround steps. Guest-service tasks
remain separate and do not acquire these room-cleaning defaults.

Migrations 49–51 initialize defaults for existing/new hotels, add reviewed save
commands/history, expose scoped setup data, connect workflows and serialize first
financial-record creation with currency changes. History is not fabricated for
pre-migration edits. Verify with `022_property_settings.test.sql`,
`npm run test:settings` inside `apps/web`, and
`python3 supabase/tests/settings-concurrency.py`. The race check uses isolated
hotels and deletes its own records. Build both `apps/web` and `apps/guest-portal`
when changing guest-facing settings rendering.


## Reports & insights

Open **Reports & insights** in the hotel sidebar. Each hotel has its own report,
using its current timezone and operating currency. Date ranges include both
endpoints (1–366 days); comparisons use the immediately preceding equal-length
period. Tabs cover overview, reservations, charges/cash, and service performance,
with an inspectable daily trend and complete daily CSV export. Breakdown exports
are available for booking sources, current room types, payment methods and service.

Scheduled occupancy is a **current calendar snapshot**, using current active rooms,
active reservation holds and unblocked reference nights. It is not historical
check-in telemetry. Booked room value allocates recorded stay totals across nights
with exact cent remainders; booked ADR/RevPAR use that value. Posted folio charges
use business dates, direct restaurant sales use served dates, and receipts/refunds
use transaction dates in hotel time. Room-charged orders are excluded from direct
restaurant sales to avoid counting the same sale twice. Invoice credits are shown
separately from refunds. Monetary report values and CSV amounts preserve decimal
precision; chart coordinates use numeric approximations for display.

Service outcomes use completion/served dates, while creation counts use creation
dates. On-time rates exclude records without a target. Open/overdue counts describe
**current** workload across all creation dates, even outside the selected period.
Source cancellations/no-shows describe the current status of the selected creation
cohort, rather than cancellation event dates. Recorded feedback distinguishes guest,
staff-reported and legacy provenance. Older missing completion timestamps cannot
be reconstructed by reporting.

Reports reuse existing permissions: calendar aggregates require reservations or
finance/billing access; money requires finance/billing access; hotelwide tasks
require task assignment access; requests/orders follow their existing module
access. Own-task-only housekeeping has no hotelwide report access. Financial-only
roles do not acquire reservation-detail access. CSV exports enforce the same
scopes, contain no guest contact/payment references, neutralize spreadsheet formula
text, and are served privately without caching. Reports never post charges or
create financial records. Refresh explicitly to fetch current data.

Migrations 52–53 add the read-only reporting RPC, indexes and permission-aware
navigation. Validate with `023_hotel_reports.test.sql`, `npm run test:reports`
inside `apps/web`, and the web production build. SQL fixtures roll back and cover
cent allocation, blocked capacity, refund-only periods, hotel midnight/DST,
completion cohorts, current backlog and role isolation.


## Platform administration

Platform administrators use `/admin`, with a separate console for the hotel
directory and business accounts. Platform admins land here after sign-in through
the default dashboard route; **My hotel workspace** opens hotel operations for
businesses where they independently have hotel access. The console link also
appears in their hotel workspace. Platform access is granted only by a database
operator; it is never a signup option or a client-editable profile field.

To bootstrap a local admin, first create/confirm the account, then run this in the
SQL editor as a database operator, replacing the email:

```sql
insert into public.platform_admins(user_id)
select id from auth.users where lower(email)=lower('you@example.com')
on conflict do nothing;
```

The directory searches hotel name, city, business name/slug or IDs, with account
status filters and 20-row pagination. Business details show all hotels, owner
contacts, subscription entitlements, room/staff setup counts, and paginated
platform audit history. **Add business & hotel** creates the business, active
subscription, verified owner membership and first hotel atomically. The owner
must already have a verified account; setup changes no password and sends no
email. For a second hotel, find the existing business and choose **Add hotel**.
Plan capacity is checked under the same business lock used by owner-side hotel
creation. Adding hotels requires an eligible subscription. An undersized plan
cannot be assigned to an existing portfolio.

Owners complete hotel setup in their own workspace: **Manage properties →
Property settings**, then **Rooms & inventory** and **Team & access**. Owners and
business administrators automatically manage all their business's hotels;
property-level staff need separate assignments. Platform admins can inspect
hotel identity and setup counts, but do not automatically see guest identities,
reservations, inbox messages, hotel payments or hotel reports. Platform management
does not impersonate an owner or provide operational hotel configuration access.

Plan and account status changes require a reason, review, and the business slug
as confirmation. Changes apply to the **whole business**, including all hotels.
Stale admin forms are rejected; retrying an identical request is idempotent. The
audit stores actor, reason and before/after values. Even admins who also own a
business cannot change status/version with a direct client update. Legacy admin
RPCs use the same validation and locking rules; the older plan API records a
legacy-API reason. Plan reference prices are displayed, but these actions do not
charge cards, create subscription invoices, or perform payment-provider billing.
Assigning a plan makes the subscription active and clears its old period-end date.

Suspended/closed business accounts retain their records. New authenticated hotel
operations and guest portal access are blocked; owners cannot undo the platform
status. Members can still read the account status to see a recovery message.
Other active businesses under the same login remain available. Reactivation
restores access and unexpired guest links without duplicating data. Account status
does **not** stop integration workers or revoke provider credentials; provider
connection management remains separate. No channel-manager changes are included.

Migrations 54–57 implement scoped platform read models, audited commands, status
access gates and consistency fixes. Validate with `003_platform_admin.test.sql`,
`024_platform_management.test.sql`, `npm run test:platform` in `apps/web`, and
`python3 supabase/tests/platform-concurrency.py`. Concurrent retries, competing
admin edits and owner creation versus plan downgrades use disposable fixtures
that the script removes. The original platform test now scopes its tenant/audit
counts to its own fixtures so it can run alongside seeded local data.


## Web theme and typography

The staff web app and platform console use warm white surfaces, charcoal text and navy blue accents. Shared brand
colors live in `apps/web/src/app/globals.css` (`--brand-primary`, `--brand-hover`,
`--brand-soft`, `--brand-focus`). Feature styles keep paragraphs and borders neutral, reserving navy blue for primary
actions and active navigation; semantic status colors remain distinct. Body text is 16px, with
most paragraph/table/navigation text at 15–16px and compact metadata at 12–14px.
Desktop sidebars scroll on shorter viewports so larger navigation does not hide
links. The report chart uses neutral charcoal lines. The separate guest portal has
not been restyled as part of the staff-web theme change.


## Hotel navigation and property switching

The hotel workspace uses a Discord-inspired two-column sidebar: a narrow property
icon rail and a dark navy navigation panel. Features stay filtered by the current
hotel's permissions and are grouped into Front desk, Daily operations, Management
and Your business. The navigation list and property rail scroll independently;
the selected hotel's switcher and account footer stay in place.

The hotel header opens a searchable property picker with the current selection,
hotel names and timezones. Switching from the picker or icon rail always opens
the destination hotel's overview so the new hotel's permissions can determine
navigation, without carrying reservation/guest URLs across properties. Owners and
business administrators see Manage/add properties for the current business.

At 800px and below, the sidebar becomes a menu drawer with a backdrop, Escape
handling, keyboard focus containment and a close button. The picker supports
keyboard Tab navigation, Escape and outside clicks. A skip link goes directly to
the main hotel content. Styling is scoped in
`apps/web/src/components/workspace/navigation.css`; platform admin navigation is
separate. Run `npm run test:workspace` in `apps/web` for routing, initials and
property-search checks, and build the web app after navigation changes.


## WhatsApp content preparation

Use **Guest messaging** in the hotel sidebar to prepare message templates, hotel
links, menu options and journey plans before connecting the API. It includes eight
starters, a sample WhatsApp preview, named variables, photo/button definitions,
role-scoped editing, revision checks, audit history and preparation JSON exports.
**Content reviewed** is separate from Meta approval. Journey plans and the menu
simulator do not run live automation or send messages. See
[WhatsApp preparation](whatsapp.md#prepare-guest-messaging-before-api-setup) for
setup steps, current guest-portal actions and remaining delivery integrations.
Migrations 58–61 must be applied. Build both apps; validate with
`025_whatsapp_template_studio.test.sql`, `npm run test:guest-messaging` in
`apps/web`, and `python3 supabase/tests/whatsapp-studio-concurrency.py`.


## Advanced guest portal

The guest app now provides a mobile stay hub, reservation-scoped arrival details,
document-status/upload workflow, reviewed dining cart, request tracking and
feedback, a read-only bill, hotel guide and an installable shell. Arrival
submissions appear in staff reservation details. Guest commands are idempotent
and stay-scoped; check-in/checkout assistance never changes the reservation state.
See [guest portal](guest-portal.md#advanced-stay-workspace) for link destinations,
PWA privacy, Edge Function prerequisites and validation commands. Apply migrations
62–67 and build both apps. Guest production artifacts use `.next-production`,
separate from `.next-dev`, to keep local dev and production checks independent.

## Group reservations and group walk-ins

Reservations now offers **Group booking**, with **Group reservation** and **Group walk-in & check in** modes. The single-room booking page links to the same flow. Existing groups are available from Reservations → More → Group bookings.

A group contains 2–50 normal room reservations sharing arrival/departure dates. Staff can mix room types, rate plans and guest counts. The first room holds the lead guest; other rooms can use that same profile, another new guest, or a returning guest from this hotel. Shared profile edits apply to all bookings using the profile. Use separate guest profiles and verified contact permissions for individual room messaging. Each room retains its own admission checks, documents, bill and event messages.

Availability previews allocate distinct rooms, respecting explicitly selected room IDs in API requests. Final creation serializes allocation within the property, rechecks prices and room holds, and rolls back the entire group if a room cannot be booked. A stable creation request prevents duplicate groups; only a SHA-256 hash of the reviewed request is retained for comparison, rather than a second copy of contact details and permission evidence. Group walk-ins additionally attempt the existing check-in action for each saved room. Missing documents or other normal admission blockers leave that room confirmed, with its reason displayed; they never bypass the check-in gate.

The group page provides bulk check-in/checkout using the existing version-checked batch action. Completed checkouts still require settlement and create cleaning work. Individual stays link back to their group. Apply migration `20261105000111_group_bookings.sql` before deploying these pages.

Local verification:

```bash
npm run test:reservations --prefix apps/web
PGOPTIONS='-c search_path=public,extensions' psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -X -v ON_ERROR_STOP=1 -f supabase/tests/111_group_bookings.test.sql
python3 supabase/tests/group-booking-concurrency.py
```

The database suite rolls back its fixtures. The concurrency script creates and removes an isolated local hotel; it cannot target hosted Supabase. Inspect pgTAP output for `not ok` as well as SQL errors. Browser QA uses local Supabase and synthetic rooms/guests, including a fifty-room reservation and partial group checkout. It does not send real guest messages.

### WhatsApp automation setup

Templates are shared by three separate sending flows. Create or sync approved templates in **WhatsApp Automation → Templates**, then assign them to:

- **Booking welcome**: use the editable starter with a personal document-task link and an optional photo. Submit revisions under a new template name; the current approved welcome remains assigned until its replacement is explicitly selected. Choose the approved welcome, then turn it On. It sends once per confirmed booking with recorded prior contact permission, including a returning guest's new booking. Turning it on does not enable document admission gates or other events, and does not replay old bookings.
- **Guest menu**: configure categories and services, assign each service's approved template, then publish. Each distinct Hi, Hello or Menu receives a reply; provider-message IDs and processed inbound jobs still prevent duplicate webhook replies. Published services use their assigned template, including its photo and personal task link. Native check-in/out confirmations retain the document, room and settlement checks.
- **Event messages**: choose a predefined event, select a compatible approved template, and activate it. Timed reminders use the hotel's timezone. Booking welcome is managed separately; old `tab=rules&event=booking_confirmed` links still open it.

**Inbox → Free text → Photo** accepts JPG/PNG up to 4 MB with an optional 1,024-character caption while the guest's 24-hour reply window is open. The app decodes and rebuilds the image, stores it in the private `whatsapp-inbox-photos` bucket, and queues the existing image transport. Delivery links last seven days; authorized staff receive fresh short-lived links when viewing history. Duplicate submissions use the same conversation/request ID. Delivery and retry recheck opt-out, identity reset, hotel/sender status, the reply window and attachment expiry. Outside the reply window, use an approved photo template. No additional scanner server is needed for these image attachments.

Migration 112 adds the private attachment bucket, protected metadata, photo commands and flow updates. Local regression: `supabase/tests/112_whatsapp_simple_flow.test.sql`; run it with the affected WhatsApp tests 032–035, 043 and 048. Web regression: `npm run test:automations --prefix apps/web`, `npm run test:inbox --prefix apps/web`, `npm run test:concierge --prefix apps/web`, and the image validation tests. Use synthetic local recipients or provider stubs for UI tests; do not send live guest messages just to verify page layout.

Migration 113 adds approved photo-template headers and previews to manual Inbox replies. Outside the 24-hour window, choose a ready **Template** marked **Photo**; its approved text and saved image are used together. Missing images and stale approvals are excluded from ready choices. Regression: `supabase/tests/113_inbox_photo_templates.test.sql`.

## WhatsApp room and group bookings

Migrations 149–150 simplify the enquiry wizard: **check-in + check-out dates in one reply → total members → room count → booking contact → room types and quantities → review → one 50% deposit link**. Dates display as DD-MM-YYYY. Guests can mix room types and book up to 50 rooms; each selected room must have at least one member and stay within its configured capacity (maximum 30 members per room).

The review and paid confirmation include the hotel’s check-in/check-out times and timezone. A single-room booking uses the existing reservation flow. Multiple rooms create an ordinary `reservation_groups` entry and one reservation/folio per room, visible in Reservations → More → Group bookings. Each room keeps the existing document, admission, service and checkout guards. The booking contact can send Hi to select the relevant room’s stay; confirmation does not grant ongoing updates or marketing consent.

All rooms are held for 15 minutes. Inventory allocation and price revalidation are atomic: failure to allocate any room rolls back the whole group. The hotel’s connected Razorpay account receives one captured deposit. `hotel_payment_allocations` distributes that receipt across the individual folios in paise; its entries sum exactly to the captured amount. Verified refunds are similarly distributed, with no folio refunded beyond its receipt. Repeated callbacks do not duplicate receipts, refunds or confirmation messages. A late capture is recorded for staff review and never recreates released rooms. A confirmed group is not re-finalized when later reconciled after check-in.

Validate locally with `135_whatsapp_enquiry_bookings.test.sql`, `150_whatsapp_group_booking.test.sql`, `114_online_payments.test.sql`, `111_group_bookings.test.sql`, `148_whatsapp_public_hotel_replies.test.sql`, and a hotel app build. These SQL tests roll back their synthetic data; they do not charge a merchant or send guest messages.
