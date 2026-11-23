# WhatsApp-first guest journey

Open **WhatsApp Automation → Guest journey** for the selected hotel. Enable the journey, set the number of required identity documents, and choose whether guests may confirm check-in in chat. Existing hotels remain disabled until their owner configures this feature. Saving the journey does not submit templates or enable event rules.

The hotel must already have a working WhatsApp connection. Use a dedicated test stay and the hotel’s connected sender when testing. The built-in menu works without a saved custom menu; an owner-published menu retains its categories and template replies. Stay details, document upload, food, service requests, check-in and checkout actions from that menu use the new journey handler when enabled.

## New booking and first contact

For repeat visits, select **Guest profile → the returning guest** when making the booking. This explicitly reuses the profile and verified WhatsApp binding; a matching typed phone never automatically merges people.

Create and approve a **Booking confirmed** utility template, then enable its event rule with delay 0. The revised starter contains hotel/stay details, the secure document task link and “Reply Hi” for preferences. It may have a hotel photo header and static public link buttons. Meta approval remains required; template creation and sync do not send guest messages.

When making a direct booking, record the guest’s prior permission for the booking welcome using the checkbox and evidence field. Booking creation and this permission record are atomic. For an existing unexpired captured welcome, the reservation detail page can record the evidence later. A phone number alone is not permission. OTA adapters must supply verified permission evidence through a separately authorized integration before this path can be used; importing a reservation does not invent consent.

The first welcome is captured automatically by the booking transaction and sent by the existing automation worker. Without prior contact permission it remains held with an explanation in Delivery history. Recording this permission never grants ongoing stay updates or marketing, and never overrides STOP. Turning on a rule does not backfill historical bookings or resend an expired welcome.

## Guest conversation

1. The guest replies Hi. A unique, previously verified booking contact is offered **Enable stay updates**, **No automatic updates**, and **Optional offers**. An ambiguous or unknown number is handed to reception without showing private information. These are real interactive buttons, not a portal consent form.
2. Choosing updates records the real inbound message, time, purpose and wording version. The guest gets document-upload guidance, a guest-menu button and a separate optional-offers choice. Declining updates still permits guest-requested help during the current reply window; it does not enable automatic event messages. STOP UPDATES, STOP OFFERS and STOP revoke their respective scopes.
3. Documents open only the secure document page. Identity files remain private until their configured checks finish: photo-only review rebuilds JPG/PNG images inside the hotel app; antivirus mode requires a successful scanner verdict. Neither check approves the identity automatically. Staff use **Reservation → Arrival documents & check-in readiness** to open a short-lived audited review link and approve or request replacement. A completion event is captured only after the required identity-document review is complete.
4. Configure **Arrival reminder** for 120–180 minutes before the hotel’s local check-in time. Approved messages include the time and “Reply CHECK IN”. Check-in requires approved documents, the booked date, arrival time, an active clean room and no other checked-in guest. The guest explicitly confirms; the reservation, audit and configured check-in event are updated together. Staff status changes also enforce the document gate.
5. Hi opens the owner’s published menu or the built-in menu. Stay details are displayed in WhatsApp. Food opens the exact food-selection helper; order templates report dishes, quantities, amount and room. **Request a service** lists the hotel’s active service catalog with paging. Selecting and confirming creates a real WhatsApp-source request and uses existing staff task routing. Repeated requests reuse the same unfinished catalog request. Reception handoff pauses automatic chat replies.
6. Checkout asks the guest to confirm, posts the full booked room nights and checks settlement and unfinished food orders. An unsettled stay remains checked in and offers the bill/reception options. A settled stay checks out, releases future inventory, marks the room dirty, queues cleaning and sends a confirmation. The final confirmation remains deliverable after the reservation closes.

Menu buttons bind the conversation, sender connection, phone, reservation, configuration revision and reservation revision where needed. They expire after 30 minutes and cannot repeat an operation. Provider redelivery and worker retries are deduplicated. Connection status, STOP, reply-window expiry and handoff are checked again before sending. Existing custom template replies continue to require compatible approved templates; these deterministic actions are not a general-purpose AI bot.

## Event templates

Every proactive event requires an enabled rule and an approved current template. New starter messages contain actual details rather than a generic portal-homepage link. Existing approved templates are preserved; create a revised template under a new name and explicitly assign it to replace older generic text.

Additional fields: `check_in_time`, `check_out_time`, and order-event-only `order_summary`. The order summary is read after the committed order items exist. A `portal_url` on the welcome/document messages opens documents; invoice/payment/checkout reminders open billing. Other personal links stay reservation-specific. Rich event templates now support static text/photo headers, an optional footer and up to two static public HTTPS URL buttons. Carousels, video/document headers and dynamic public buttons remain unsupported. Rich templates do not automatically become campaign-compatible; campaign transport retains its existing limits.

Configure the corresponding rules for document receipt/approval/rejection, check-in, food placed/preparing/ready/served/cancelled, service received/started/completed/cancelled, payment/refund/invoice and checkout. Reviews require separate marketing permission. Freeform menus/actions use the guest’s current 24-hour reply window; approval does not grant an unlimited freeform window. [WhatsApp messaging policy](https://whatsappbusiness.com/policy/).

## Document file-check mode

The default is **Hosted photo-only review**: no separate server, JPG/PNG only, actual decoding and fresh JPEG output, followed by manual staff approval. PDFs are disabled and no antivirus scan is claimed. See [guest document handling](guest-tasks.md#hosted-photo-only-review). The scanner warning is displayed only when the hotel chooses antivirus mode.

## Optional antivirus scanner deployment

The scanner is a separate continuous process, not a Vercel web function. From `services/document-scanner`:

```bash
cp .env.example .env
# Set SUPABASE_URL and the server-only SUPABASE_SERVICE_ROLE_KEY.
docker compose up -d --build
docker compose logs -f scanner
```

The compose file runs the scanner alongside the official ClamAV daemon with persistent virus signatures and no public antivirus port. The first startup downloads signatures and may take several minutes. ClamAV TCP has no authentication or encryption; keep it on this private network. [ClamAV Docker documentation](https://docs.clamav.net/manual/Installing/Docker.html).

Alternatively, run `npm ci && npm start` with the configured `.env` and a private existing ClamAV daemon. The Guest journey screen shows the scanner’s recent heartbeat and pending-file count. The worker checks the daemon before claiming files. Only a literal successful antivirus verdict releases quarantine. Infection is blocked; download mismatch, timeout, malformed response or unavailable scanner retains quarantine and retries later. Leases prevent two workers scanning the same document and reject stale acknowledgments. No antivirus verdict was fabricated to test guest check-in. Local SQL fixtures explicitly represent previously scanned documents.

Deploy migrations 91–96 and the existing `guest-documents`, `document-access` and updated `whatsapp-worker` functions. No new browser secrets are required. Keep the scanner’s service-role credential server-side. Review the existing worker’s automation feature flag and trusted guest portal origin before enabling hotel rules. Antivirus-mode document review cannot complete until a scanner is actually running. Photo-only review is a separate configured path and never fabricates a clean scan.

## Validation

`043_whatsapp_guest_journey.test.sql` covers automatic welcome capture, contact-permission holds, no implicit ongoing/marketing consent, in-chat choices, document gating, check-in, request/task routing, replay/expiry/STOP handling, checkout balances/orders, inventory release and cleaning. `044_document_scan_leases.test.sql` covers quarantine and scanner leases. Node scanner tests cover explicit clean/infected verdicts, malformed replies, timeouts and oversized files. Provider delivery must additionally be tested against the real connected number; local assertions do not establish live delivery.

## Missing booking welcome

A reservation now shows the actual booking-welcome configuration and delivery
state. The new-booking form warns when the journey or welcome rule is off.
Enabling a rule does not silently backfill previous reservations. For a confirmed
booking created within the last 24 hours, with recorded prior contact permission
and a ready approved template containing `portal_url`, an authorized reservation
writer can select **Send booking welcome once**. Repeated requests, concurrent
clicks and queued/sent messages reuse the original deduplicated event.

This initial contact permission remains separate from ongoing stay updates and
optional marketing. It never opts the guest into either scope. Other event rules
still require the owner's deliberate template assignment and activation.
