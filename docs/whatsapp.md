# WhatsApp (Cloud API) design notes

**Flow in:** Meta -> `supabase/functions/whatsapp-webhook` (verifies `X-Hub-Signature-256`, handles the GET handshake) -> `ingest_whatsapp_inbound` / `ingest_whatsapp_status` (service_role only). The phone-number ID routes each event to the property that owns it; unknown numbers are acknowledged and ignored. Events are deduplicated by `(connection, event_key)` and messages by wamid, so Meta retries are safe (the function returns 500 on failure so Meta does retry).

**Flow out:** the staff Inbox calls `inbox_send` with a request ID (permission `whatsapp.use`); `send_whatsapp_message` remains a compatibility wrapper. It enforces opt-out and the 24-hour window (free text only within 24h of the contact's last message; otherwise an approved template) and enqueues a row. `services/notification-worker` claims rows with attempt numbers (`FOR UPDATE SKIP LOCKED`), checks eligibility again, calls the Cloud API, and records the result; confirmed transient rejections retry with exponential backoff, while uncertain outcomes require reconciliation (see v2 below). Statuses that arrive before the worker records the wamid are replayed on completion; out-of-order statuses never move a message backwards.

**Consent:** `consent_records` is append-only; STOP/UNSUBSCRIBE and START/SUBSCRIBE keywords are recorded automatically; the latest row wins.

**Secrets:** only `credentials_ref` is stored in Postgres. Tokens belong in Vault; the dev worker reads `WHATSAPP_TOKENS_JSON`. Service-role keys exist only in the edge function and worker environments.

**Preparation workspace:** local template authoring, named variables and sample previews, photo-header drafts, URL/quick-reply definitions, hotel links, guest-menu configuration, journey plans, a simulator and preparation JSON exports now exist. These are offline content/configuration features.

**Live integration:** provider template sync, text body variables, hotel domain-event hooks, scheduled reminders, explicit guest authorization/binding and secure stay links are implemented in the separate [Automations workspace](whatsapp-automations.md). The guided WhatsApp messages workspace supports explicit in-app submission to Meta, approval sync and event selection. Interactive service-window menus, public links, verified guest-page buttons and photo replies are implemented in the [live guest menu](whatsapp-guest-menu.md). Proactive media/button templates, arbitrary conversational AI, guest self-verification, full provider quality monitoring and activation of old offline journey-plan records remain unimplemented. Cloud API Embedded Signup, encrypted hotel credentials, connection checks and disconnect/reconnect controls are implemented separately; see [onboarding requirements and remaining Meta setup](whatsapp-onboarding.md).

## Advanced staff inbox

The shared Inbox now provides contact search, open/resolved and assignment
filters, human-handling filter, per-staff unread markers, a complete paginated
conversation list, and latest-first retrieval of message history. Older history
uses a stable `(created_at, id)` cursor; each displayed page is chronological.
The latest page refreshes on demand or every 15 seconds while visible and not
editing a field. Drafts stay in component memory during refresh. They are not
stored across full reloads or conversation changes.

Owners can claim a conversation without manually adding themselves as property
members. Managers can assign eligible staff; ordinary staff cannot steal an
assigned conversation by claiming it. Assignment changes use version checks.
Resolved conversations must be reopened before replying. Human handling is a
coordination flag; automated response rules are still not implemented.

Replies use request IDs to deduplicate a retried submission. The composer shows
approved template language and body previews. Templates with variables and media
previews are explicitly unavailable. The application enforces opt-out and its
24-hour free-text reply window in SQL; queued messages are checked again before
delivery. Queued, sent, delivered, and read remain distinct states.

Hotel administrators can open Connection setup to save business-number IDs,
display phone, a server credential reference, and pending/enabled/disabled state.
This is configuration, not proof of Meta verification. Credentials must already
exist in the server environment, and webhook and worker deployment remain
required. Do not enter an access token into the credential-reference field.
Approved templates must already be synchronized into `message_templates` by the
provider/admin integration; the UI does not approve or submit templates to Meta.

## Delivery worker v2

Rebuild/restart `services/notification-worker` after applying migrations 0020–0023.
It uses `claim_outbound_messages_v2`, `validate_outbound_claim`, and
`complete_outbound_message_v2`. Claims carry an attempt number; stale attempts
cannot overwrite a newer claim. HTTP calls have a 20-second deadline. Explicit
provider throttling/transient failures retry with backoff, bounded by five
attempts. Permanent rejections fail without automatic retry. Network errors,
missing provider IDs on accepted requests, and expired abandoned claims become
uncertain failures, requiring provider reconciliation before another send.
Acknowledgment failures are logged separately and never treated as an HTTP-send
failure. The Inbox offers retry only for failures without a provider ID or an
uncertain outcome, subject to current consent/window/template checks.

Run `npm test` in the notification worker for mocked transport tests,
`npm run test:inbox` in the web app for filter/state checks, and
`supabase test db supabase/tests/015_advanced_inbox.test.sql` for transactional
Inbox/queue tests. These tests never send real WhatsApp messages.


## Prepare guest messaging before API setup

Open **WhatsApp messages → Advanced → Open message drafts & hotel links**.
For live templates, use **Message templates** in the guided workspace instead. Preparation is available before a business-number connection and does
not require the current plan to include live WhatsApp messaging. Administrators
with `staff.manage` edit configuration; `whatsapp.use` staff can inspect drafts,
previews and exports. Other hotels and suspended accounts cannot access the data.
Platform-admin status alone does not confer hotel-template access.

1. In **Hotel links & menu**, save the guest portal base URL, public review link,
   directions, website/photo-gallery URL and optional default hotel photo URL.
   Public links use HTTPS. Localhost HTTP is accepted for local portal previews;
   link templates require HTTPS destinations before content review. Never save a
   real reservation token or guest-specific link in shared settings.
2. Choose a starter in **Templates**: booking welcome, pre-arrival documents,
   arrival information, in-stay services, checkout reminder, review request, hotel
   guide/photo, or service update. Customize name/language, body variables, static
   header/footer, photo URL and action buttons. Review requests/guides start with a
   suggested marketing category; Meta determines the final classification.
3. The editor supports approved-in-app named fields such as `{{guest_name}}`,
   `{{hotel_name}}`, arrival/departure dates, booking reference, room, hotel times
   and service-request status. Header/footer text remains static. Use up to two
   URL buttons or three quick replies; mixed configurations are not supported.
   Preview values are fabricated examples and never create a guest token.
4. Save as **Draft**, or **Content reviewed** after completing the checklist.
   This state is internal and never marks an item Meta-approved. Drafts remain in
   `whatsapp_template_drafts`; they do not become `message_templates`, appear as
   sendable Inbox templates, or enqueue outbound messages. Linked prepared plans
   must be unprepared before a template can be archived. Duplicate a template to
   prepare a variation or another language.
5. In **Journey plans**, choose a matching template for booking received,
   pre-arrival, staff-confirmed check-in, pre-checkout, completed checkout or
   completed guest service. Select direct/walk-in/OTA sources and minutes before
   or after the relevant event. Preparing a plan only saves configuration; it
   installs no scheduler or channel-event hook. OTA includes Agoda and other
   providers represented by the existing `ota` source, rather than a new Agoda
   integration.
6. In **Test the experience**, simulate missing phone, messaging permission,
   opt-out, source exclusion and human handoff. Try MENU/HI/HELLO, RECEPTION/HUMAN,
   STOP/UNSUBSCRIBE or unknown text to preview menu/fallback behavior. No actual
   consent, conversation, booking, service request or WhatsApp message is changed.
7. From a saved template, export **preparation JSON**. The export includes a
   Meta-shaped draft, positional variable examples/mapping and planned portal
   suffixes. It explicitly says `not_submitted: true`. Image headers still require
   a Meta media upload and returned handle; the JSON is not guaranteed directly
   submit-ready. Exports are authenticated, scoped to the hotel and not cached.

Menu options include stay details, secure document upload, room ordering,
service requests, check-in/checkout requests, review and reception. Reception is
always available as an escalation in the simulator. Guest portal links support
`#stay`, `#documents`, `#food` and `#services`. `?intent=checkin#services` and
`?intent=checkout#services` open the appropriate guest assistance request;
staff must still verify documents, room readiness and billing before changing
reservation status. Room ordering retains its checked-in requirement. The advanced guest portal now includes stay-scoped arrival details and an installable
app shell; personal stay data is never cached offline.

The future live Agoda flow is: imported reservation recorded → validate contact
and permission → match a prepared journey → bind an approved template revision →
create a reservation-scoped expiring guest link → queue an immutable personalized
payload → deliver through the worker → track provider status. A phone number on
an OTA reservation does not itself establish messaging permission. Automatic
check-in/checkout, arbitrary guest questions and document processing are not
implemented by saving a template or menu plan.

Next integration work must add server-controlled approval mapping, runtime body/
button/media parameters, durable event scheduling and deduplication, auditable
reservation/contact permission, and inbound menu routing with opt-out/handoff.
Existing consent/window checks, delivery-uncertainty handling and role boundaries
must remain in force. Changing a reviewed template must invalidate/remap the
provider revision before any future automatic delivery.

Migrations 58–61 add scoped authoring/settings/journey tables, command idempotency,
version checks, change history, validation and navigation. Run
`025_whatsapp_template_studio.test.sql`, `npm run test:guest-messaging` in
`apps/web`, and `python3 supabase/tests/whatsapp-studio-concurrency.py`. Fixture
transactions/scripts do not send messages and clean up their own data. Build
both the web app and guest portal when changing portal destinations or prefills.

Provider references: [WhatsApp Business Messaging Policy](https://business.whatsapp.com/policy)
and [Meta template API](https://developers.facebook.com/docs/graph-api/reference/whats-app-business-account/message_templates/).

## Hotel marketing campaigns

The separate [campaign workflow](whatsapp-campaigns.md) supports historical guest segments, recipient selection, draft offers, permission evidence, scheduling and delivery results. It does not activate the prepared guest-journey plans. Campaign delivery is explicitly disabled by default and requires verified approved text-only templates; arbitrary draft copy cannot be sent as unapproved bulk text.
