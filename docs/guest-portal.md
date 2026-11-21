# Guest portal and documents

**Identity model.** Guests are not Supabase users. Staff mint a link with `create_guest_portal_link` (shown once; only a SHA-256 hash is stored). The token is 244 random bits, expires after at most 30 days and never later than 3 days after check-out, and can be revoked. Every `portal_*` function derives the reservation from the token; the client never supplies a reservation, guest or property id. The portal holds only the anon key and calls these functions as `anon`; direct table access returns nothing.

**Abuse limits.** 10 requests / 10 orders per hour per stay, 10 documents per stay, length limits on text. The advanced command endpoint also caps 100 successful submissions per stay per hour; retries return the original result. Missing: IP-based throttling and failed-token lockout (add at the edge/CDN); a leaked link grants access until it expires or is revoked, so send links only over WhatsApp/SMS to the guest's own number.

**Documents.** Prepare (edge function, service role) -> signed upload straight to the private `guest-documents` bucket -> confirm (checks the stay scope, object existence, declared size and MIME metadata) -> status `uploaded`. **Staff cannot open a document until it is marked `clean`** by a malware scanner calling `mark_document_scan` (service_role). The scanner is NOT built: until you wire one (e.g. ClamAV worker), documents stay `uploaded` and unviewable (fail closed). Staff access goes through `document-access`: the database checks `documents.review`, requires a reason, writes `document_access_events`, and only then does the function sign a 60-second URL. Reviews are recorded in `document_reviews`.

**Privacy to-do before production (needs qualified counsel).** Retention and deletion schedule for ID documents, guest-record register requirements, DPDP notice and consent wording on the portal, breach response, and encryption-at-rest settings for the bucket.

**Deploy notes.** `supabase functions deploy guest-documents --no-verify-jwt` (set PORTAL_ORIGIN); `supabase functions deploy document-access` (keeps JWT verification). The portal app runs from `apps/guest-portal` (`GUEST_PORTAL_URL` in the web app points staff-generated links at it).


## Advanced stay workspace

The portal has mobile navigation for **My stay**, **Arrival details**,
**Documents**, **Room dining**, **Requests & help**, **My bill** and **Hotel guide**.
Guests use their existing personal link; there is no guest account or password.
The current hotel’s contact information, check-in/out hours, arrival instructions
and stay information come from Property settings. Directions, website/gallery,
review and optional hotel-photo links come from Guest messaging’s hotel links.
The public review link is offered after checkout without conditioning it on a
positive service rating.

Arrival details are saved to `guest_arrival_details` for this reservation only.
Guests can enter name, email, international phone number, country/address,
expected arrival time and notes. Version checks prevent another browser session
from silently overwriting newer details. This never edits the shared `guests`
record. Authorized staff see the submission on the reservation detail page;
housekeeping and unrelated hotels cannot read it. A request for stay updates is
stored as a booking preference; it does not verify phone ownership, establish a
global WhatsApp consent record, or activate automation.

Guests can request check-in assistance during their booked arrival period and
checkout assistance while in house. Repeated clicks reuse an existing open stay
request. These requests do not change reservation status, issue keys, collect
payments, bypass documents/room readiness, or settle the folio. The front desk
completes those operations through the existing staff workflow.

Room dining supports category/search filters, paginated menus, descriptions,
dietary notes, quantity controls, a cart with exact per-line tax rounding, and an
explicit review/confirm step. The server verifies menu versions, currency and
quoted total before creating one room-service order. Stale prices require a new
review. Ordering remains limited to checked-in stays with an open bill. Cart
contents remain in memory and are cleared after successful ordering; no guest
cart or token is saved to local storage. Order history shows immutable price/tax
snapshots and kitchen progress, without exposing staff-only order notes.

Service requests show received/in-progress/completed/cancelled states. Guests can
cancel only before work starts, with request version checks and matching linked
staff-task cancellation. Completed requests can be rated once. Retry IDs prevent
duplicate arrival saves, requests, feedback and kitchen orders. Pages refresh
periodically while visible/online and no form is dirty, busy or focused; a manual
refresh is always available. Guest-originated request notes are shown; staff
request comments/notes remain private.

The bill view separates the booked room amount, posted charges, receipts,
refunds, invoice credits, unposted room nights and pending food orders. The
estimate includes the remaining booked nights and pending orders once; it is not
a payment demand or a payment gateway. Invoice information is read-only; guests
request the official invoice copy from reception. Viewing a bill never creates a
folio, posts charges, or records payments. Guest ledger rows exclude processor
references, collector identities and internal refund explanations.

Document upload uses clear preparation/upload/confirmation states. A failed
confirmation can be retried for the same document without uploading it again or
reversing an existing scan/review decision. Upload preparation and finalization
are denied after the stay becomes inactive. Files remain subject to the existing
10 MB/type/count limits, private-bucket rules and scanner/reviewer workflow.

## Personal links and PWA behavior

Existing WhatsApp destinations `#stay`, `#documents`, `#food` and `#services` still
open the corresponding view. `?intent=checkin#services` and
`?intent=checkout#services` show the appropriate assistance request. Additional
views use `#arrival`, `#bill` and `#guide`. All token pages are dynamic and use
no-store, no-referrer, no-framing and no-index headers. Invalid/expired/revoked or
suspended-hotel links show a recovery screen asking the guest to contact the hotel.

The portal includes a web manifest, PNG icons and a service worker for an
installable app shell on supporting HTTPS browsers (localhost works for local
development). Install prompts depend on the browser; iOS uses the browser’s Add
to Home Screen flow. The manifest’s start URL is `/`, never a personal token URL.
Guests reopen their stay through the hotel’s original link. The service worker
caches only public icons and an anonymous offline fallback. Personal stay pages,
RPC responses, signed document links, form submissions and guest data are never
cached by the worker. Offline visitors reconnect before viewing/submitting stay
data. Changing cached public assets requires bumping the worker cache version.

## Local running and validation

Guest development uses `.next-dev`; the production build/start uses
`.next-production` with `tsconfig.build.json`. This prevents development and
production checks from deleting each other’s server artifacts. Run
`npm run dev --prefix apps/guest-portal` on port 3001. Staff-created links use the
web app’s `GUEST_PORTAL_URL` setting (normally `http://localhost:3001`).

Document uploads also require the local Edge Function runtime. Set
`PORTAL_ORIGIN=http://localhost:3001` in the local functions environment, retaining
any other function secrets, then run `supabase functions serve` with that env file.
Do not disable JWT checks globally: `guest-documents` is token-authenticated, while
`document-access` requires the staff member’s verified JWT. Production uses the
public guest-portal origin and deployed functions. The service-role key remains in
Edge/worker environments; it is never added to the guest app.

Migrations 62–67 add the stay workspace, RLS-protected submissions/events,
idempotent commands, document lifecycle checks and safe response fields. Legacy
portal APIs remain available for compatibility; the new app uses
`portal_workspace` and `portal_command`. Run:

- `supabase test db supabase/tests/026_advanced_guest_portal.test.sql`
- `npm test --prefix apps/guest-portal`
- `python3 supabase/tests/guest-portal-concurrency.py`
- Production builds for both `apps/guest-portal` and `apps/web`.

The concurrency check uses disposable stays to verify multi-browser detail
editing, order retries, assistance deduplication and guest cancellation versus
staff starting work. It deletes its own fixtures. The portal tests exercise exact
money/tax arithmetic, input boundaries and service-worker privacy. The global
security audit explicitly allows only the six token-scoped guest RPCs for anon.
