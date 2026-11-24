# Channel manager: supply API development

Status (2026-11-17): mock end-to-end flow, **Agoda sandbox product/rate/reservation workflows**, and a **Booking.com availability-only sandbox adapter**. No OTA is certified or live. MakeMyTrip is a prepared connection, not an implemented adapter. No OTA API calls have been made during development.

## Provider research and access

- **Agoda:** [YCS introduction](https://developer.agoda.com/supply/docs/introduction), [OAuth](https://developer.agoda.com/supply/docs/authentication-2025), [ARI contract](https://developer.agoda.com/supply/docs/availability-and-rates), [sandbox allotment example](https://developer.agoda.com/supply/docs/fplos-pricing-api-reference), [certification](https://developer.agoda.com/supply/docs/certification). Request connectivity-partner onboarding, client ID/secret, approved outbound IP, sandbox hotel, room/rate IDs and certification fixtures. Minimum certification covers GetProduct, SetAriV2, GetBookingList and GetBookingDetails, followed by a pilot. Implemented calls: GetProduct (type 5), SetAriV2 inventory/basic master-rate prices and restrictions (type 10), selected-property GetBookingList (type 3), and GetBookingDetails (type 4). These are contract-tested, not provider-certified. Legacy API-key authentication is not used.
- **Booking.com:** [Connectivity overview](https://developers.booking.com/connectivity/docs), [token exchange](https://developers.booking.com/connectivity/docs/token-based-authentication), [availability](https://developers.booking.com/connectivity/docs/tutorial-property-onboarding/step-14), [partner portal](https://connect.booking.com/). The portal currently says new connectivity-provider integrations are paused. Existing approved partners need a test machine account, authorized test hotel/room IDs and Reservations + Rates & Availability connection entitlements. This implementation uses B.XML inventory only; no room opening/closing or pricing changes. The worker rejects production-account tokens. If direct onboarding remains unavailable, investigate an approved upstream connectivity provider with a supported PMS API; that would require a separate adapter and agreement.
- **MakeMyTrip / Goibibo:** [official hotel-code guidance](https://homestaysawards.makemytrip.com/assets/img/nomination-guide-season4.pdf) identifies the channel-manager configuration. No public official supply wire contract was located. Request partner API specification/OpenAPI/Postman collection, sandbox, authentication, property/room/rate mapping, reservation delivery and acknowledgement rules, retry/order semantics and certification checklist from their connectivity team through the hotel partner account. Do not use consumer booking/affiliate/search APIs as supply APIs. No endpoints or payloads have been guessed.

These URLs are provider-owned sources. Access and certification are separate from local test success.

## Hotel workflow

Channels now shows three provider setup cards. Managers save a numeric external hotel ID and optional **server credential reference**. Never enter API keys/passwords into these fields. Prepared connections are paused; updating setup clears approval and pauses again. Existing rate/room data remains untouched. Map each PMS room type to its provider room ID. Staff can queue availability refreshes and inspect failed jobs/events.

Only a trusted service-role operator can call `approve_channel_sandbox(connection_id)`, after checking the referenced credentials belong to an authorized **test property**. MakeMyTrip cannot be activated. Hotel staff cannot bypass preparation through the old mock connection RPC. There is no production environment or live activation path in this release.

Migrations `20261105000068_channel_supply_setup.sql` through `20261105000072_channel_reservation_reference_lifecycle.sql` have been validated locally. Apply through the normal approved migration deployment workflow before using the new page against hosted Supabase. No hosted migrations are deployed by this development task.

## Worker configuration

Copy `services/channel-manager/.env.example` to a private environment file or configure the hosting secret manager. Node does not load it automatically: use your process manager or `node --env-file=.env dist/index.js` (Node 22). Required variables:

- `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`: server only.
- `CHANNEL_CREDENTIALS_JSON`: reference -> `{provider, clientId, clientSecret, environment:"sandbox"}`.
- `CHANNEL_SANDBOX_ENABLED=true`: explicit operator switch, default false.

Build/test: `npm ci && npm test` in `services/channel-manager`. Run a single persistent worker for sandbox certification. Do not start it against hosted data until mappings/credentials and migration deployment are checked.

Agoda requests go only to `sandbox-supply.agoda.com/api/v2/ari`; documented OAuth v2 exchange uses `supply.agoda.com`. Booking.com uses the documented supply host with a test machine-account token. Endpoints cannot be overridden by hotel input. Tokens stay in memory, cached per provider/credential reference, refreshed once on 401 or Agoda’s documented expired-token HTTP 403. Calls have a 20-second timeout, do not follow redirects, and record generic errors instead of response bodies or credentials. HTTP 207 and semantic errors fail; a successful push means **accepted by the provider**, not reconciled downstream state. Availability updates do not reopen manually closed rooms.

## Reliability

- Holds enqueue coalesced availability jobs. Each push recomputes current inventory instead of sending queued counts.
- V2 claims filter paused connections/inactive tenants, require sandbox approval and return a fresh lease token. Completion with an old token is ignored. New work for a room waits while a previous job runs; one job is claimed per worker cycle to avoid lease expiry while waiting behind a long batch.
- Retry/backoff/dead-letter behavior and attempts remain in SQL. A crash after accepted inventory but before completion can repeat the same absolute availability update.
- Mock feed now reads without draining; each source event is removed only after durable inbox ingest. Retries deduplicate by the outbox row ID. Agoda uses durable selected-property polling; its published FAQ states booking acknowledgement is not supported through the API. No acknowledgement endpoint has been fabricated. Booking.com reservation retrieval/acknowledgement is not implemented.
- Existing unit allocation/exclusion constraints prevent overlapping **local room allocations**. This cannot guarantee no OTA overselling: remote inventory propagation and reservation retrieval can lag. Failed imports remain visible for staff review.

## Remaining work before any live OTA support

1. Validate Agoda product discovery, rates and reservation retrieval against real sandbox responses; confirm OAuth and generic `/api` availability for the assigned sandbox account.
2. Extend beyond basic master-rate nightly pricing / stop-sell / CTA / CTD / LOS: occupancy-specific prices, child-age rates, advance-purchase limits, tax/meal/cancellation models and additional pricing models. Booking.com pricing remains unimplemented.
3. Extend the Agoda snapshot importer to multi-room allocation, Agoda Collect settlement, extra-bed booking, amendments/cancellations after billing activity, penalty accounting and richer group/settlement resolution workflows. Currently only single-room Property Collect reservations import automatically. Non-representable cases are durably visible as failed/dead events, never guessed into the PMS. Booking.com and MakeMyTrip reservation parsers are unimplemented.
4. Scheduled reconciliation, missed-booking recovery, stale-push repair and operator alerts.
5. Access/certification, sandbox E2E and live hotel pilot. Do not describe prepared connections as connected/live.

## Validation

Worker tests stub HTTP: XML dates/limits, malformed/unsafe XML, auth/token cache, refresh, sandbox gate, production Booking.com rejection, partial errors and secret-safe failures. Database tests exercise setup permissions, paused claims, approval, legacy bypass protection, leases and existing mock reservation/sync regressions. Tests never call OTAs or send messages. Frontend production build checks compilation; visual device review is separate.

## Expanded distribution coverage

The searchable Channels catalog separates OTA, rental/specialist, GDS, wholesaler and metasearch routes. See [distribution-roadmap.md](distribution-roadmap.md) for requested brand coverage, official references and dependencies. Catalog presence never enables an adapter.

## Agoda workflow details

Official contracts: [product management](https://developer.agoda.com/supply/docs/product-management), [booking retrieval](https://developer.agoda.com/supply/docs/booking-retrieval), [booking FAQ](https://developer.agoda.com/supply/docs/faqs-1), and the ARI/OAuth references above.

- **Discovery:** the worker fetches a strictly hotel-scoped product catalog containing currencies, room IDs/price limits, master vs derived plans, NET/SELL basis, tax inclusion and room/rate pairs. Card data is not part of this DTO. The page displays provider products and requires discovered master rates for rate mapping. A mapped connection cannot be reassigned to another provider hotel silently.
- **Rates:** staff explicitly enters prices in the discovered rate's monetary/tax basis; PMS base rates are not silently converted to OTA net prices. `set_channel_rates` validates permissions, property currency, mapped products, exact two-decimal amounts, provider min/max price, future hotel-local dates and a maximum 366-night edit / 730-day horizon. The date range end is exclusive in our UI/DB and encoded as individual inclusive nights for Agoda. Unspecified closure/restriction fields are omitted from requests so existing remote settings stay unchanged. Max LOS 0 removes that limit. The worker sends current calendar values after availability and retries the absolute updates on failure. Changing a rate mapping after calendar data exists requires operator review.
- **Reservation polling:** one leased checkpoint per connection, initial recovery of the preceding 24 hours, catch-up chunks of at most 55 minutes with five-second overlap, then a five-minute cadence ending 30 seconds behind now. Each poll includes GetProduct and property-scoped GetBookingList. Details are requested in batches of at most 50; missing, wrong-hotel or older-than-list details fail the window without advancing its checkpoint. A longer historic recovery needs an operator-controlled backfill design; this is not an unlimited historical importer.
- **Inbox:** event IDs derive from provider booking ID, revision timestamp and status. No raw XML is stored; normalization explicitly whitelists booking fields and removes payment/VCC details. Null ingest results are checked against the durable inbox so a paused connection cannot be mistaken for a duplicate and lose its event. Reconfiguring/pausing a connection invalidates an in-flight poll lease.
- **Snapshot lifecycle:** full-state AmendBooking can create a missing local reservation, so a missed earlier create does not lose the booking. Stale revisions are ignored; conflicting statuses at the same revision are reviewed. A cancellation before creation records a tombstone, and a late create cannot resurrect it. Newer observed events supersede older snapshots even when the newer event needs review. Failed amendments roll back allocation changes. Reservation cancellation does not post refunds, penalties or fake payments.
- **Conservative automatic-import scope:** a single room, Property Collect, valid currency/occupancy and no extra bed. Agoda Collect net receivables are retained in the review event, not falsely added as guest debt. Multi-room, extra beds, unsupported precision, missing pricing, currency mismatch, no inventory, checked-in/completed stays and reservations with a folio require review. These are not certified support claims. Staff must check Agoda directly and handle the actual group/settlement changes; the local review workflow below records the decision without fabricating those operations.

No Agoda partner/sandbox access is available in this session. Network transport was tested using injected HTTP fixtures only. No provider request, partner application or live activation has been made. Hosted Hospitality remains at its previously approved schema until these migrations are explicitly deployed.

## Staff import review

Open **Channels → Review reservation imports** (`/p/<property>/channels/review`). Failed Agoda snapshots become one case per provider booking. The queue supports open/resolved views and 20-row pages; case detail shows a whitelisted booking snapshot, its import error, any linked stay and the latest 30 staff audit actions.

Managers can:

- **Retry:** after correcting mappings or inventory, queue the stored snapshot for another attempt. The case stays open until processing succeeds. Unsupported group/settlement cases cannot be fixed by retrying alone.
- **Link:** select a reservation already recorded in this hotel. Requires reservation-write access and a complete single-room Property Collect snapshot. The server verifies dates, adults/children, currency, exact total, active room hold/type, provider-booking conflicts and existing links. Only source/reference metadata changes, with a reservation audit event; financial amounts and holds stay intact. Links are not inferred from similar names. Candidate lookup is limited to 30 matching stays; complex groups/settlements use manual resolution.
- **Record manual resolution:** after the operator actually handles the booking in Agoda and the PMS, record why and explicitly confirm inventory/financial work was performed. This does not create, cancel, move, charge, refund or acknowledge anything externally.

Linking/manual resolution puts the provider booking into sticky **manual handling**. Replayed or older resolved snapshots are suppressed; a genuinely newer revision reopens the case without creating a duplicate stay. Conflicting statuses at the same timestamp reopen review. There is deliberately no button to switch a manually managed booking back to automatic import. Previously automatic cases can recover through retry and retain automatic handling.

Commands pin a case version, use a unique request ID and compare replay payloads. Six concurrent retries produce one audit action. Competing decisions reject stale versions. Worker imports and staff decisions use the same event/booking/case lock order. Audit records store the actor, time, action and reason, with no authenticated direct-write policy. Changes to the provider after the reviewed revision require refresh. Hotel scope and active-account permissions are enforced in SQL.

Migration 72 fixes reservation references during tenant teardown by using SET NULL for provider/review links. Local concurrency tests clean their disposable hotel and authentication fixtures after completion.

Validation: review pgTAP suite, frontend snapshot/link-eligibility tests, concurrency tests for replay/competing resolutions/worker-versus-staff, and web production build. No hosted deployment, provider calls or visual browser testing occurred in this step.


## Connecting an existing Agoda hotel account

A Partner Portal email identifies the hotel login; it is not a Supply API credential. First sign in to [Agoda Partner Portal](https://ycs.agoda.com), select the correct property and obtain its Agoda Property ID. Check the top-right menu for **API access**. Agoda documents client ID/secret management and outbound-IP whitelisting on that page: [OAuth authorization](https://developer.agoda.com/supply/docs/authentication-2025). If it is unavailable, ask Agoda support which connectivity-partner/API access is available for the account and property.

Property authorization is a separate step. Agoda documents selecting an approved channel manager under Property → Property Settings → Optional Settings, or requesting property API access from its support team: [Connecting to a property](https://developer.agoda.com/supply/docs/connecting-to-a-property). An ordinary hotel login or a live hotel ID does not establish sandbox access or provider certification.

Keep portal passwords, OTPs and client secrets out of chat, Git and hotel-facing forms. Use the worker's private `CHANNEL_CREDENTIALS_JSON` for authorized API credentials and save only the reference in the hotel's Channels setup. Verify API access and the assigned test hotel's room/rate catalog before attempting inventory or rate updates. This implementation deliberately retains its sandbox-only guard; do not label a real production hotel as a sandbox to bypass it. The first provider validation should retrieve authorized products before any outbound rate or availability test.

Local transport regression now covers Agoda's HTTP 403 expiry response: one token refresh, the identical request body/property on retry, reuse of the replacement token, bounded failure on permanent denial, and unchanged Booking.com 403 behavior. These tests use simulated responses; they do not authenticate a real Agoda account.
