# Focused guest tasks in the hotel app

Guests use WhatsApp as their main hotel conversation. When a browser task is
needed, the hotel's main app serves a single public, stay-token-authenticated page:

| WhatsApp choice | Hotel app page | Visible content |
| --- | --- | --- |
| Upload identity documents | `/s/<private-token>/documents` | Upload and document status |
| Order food | `/s/<private-token>/food` | Food selection, cart and food-order history |
| Request bill | `/s/<private-token>/bill` | Charges, payments and itemized activity |

These pages have no guest tabs, hotel sidebar, dashboard or staff sign-in. Each
has a return to the hotel's connected WhatsApp conversation when a sender is
available. Staff authentication and authorization remain required on staff routes.
Public pages use the anonymous Supabase client; the stay token is their authority.
Tokens remain reservation-scoped, expiring and revocable; this change does not
claim that their authority is restricted to one task. The focused workspace RPC
returns the selected task's data rather than serializing all guest sections.

Existing configured arrival, service, check-in and checkout browser links also
open one focused form, for compatibility. Current WhatsApp-native check-in,
checkout, requests, consent and menu actions keep their existing behavior.

## One-time identity upload

The document page shows four states: upload, received/review pending, approved,
and replacement required. Once enough required identity documents are received,
the upload form closes. The server's upload preparation RPC also refuses duplicate
identity uploads while review is pending or complete. A rejected or security-blocked
file reopens the missing document requirement. Approved documents are retained and
do not need uploading again. The owner can configure more than one required
identity document in the existing WhatsApp journey settings.

Configured file checks and authorized hotel review are still required. Hosted
photo-only review (migration 101) rebuilds JPG/PNG files in the hotel app; PDFs
are disabled in that mode. It requires no scanner server and never claims an
antivirus verdict. Hotels explicitly selecting antivirus mode still need the
scanner. Neither path auto-approves identity documents. `documents_rejected`
also captures security-blocked files, so the existing enabled failure automation
can send its assigned approved replacement template. Sending still requires the
hotel connection, applicable guest permission and a ready template; this change
does not silently activate rules. Initial welcome and delivery deduplication stay
intact. Received/approved pages never prompt an unnecessary repeat upload.

The browser calls the hotel app's `/api/guest-documents` proxy for preparation and
confirmation. It forwards only the guest token and permitted fields to the
existing signed-upload Edge Function, using the public API key. It forwards no
staff cookies or service-role credentials. The bytes still upload directly to the
private Supabase document bucket. Existing Edge Function CORS configuration can
remain compatible with older links because the new browser preparation request
is same-origin to the hotel app.

## Links and deployment

Staff use the task selector beside **Create task link** on a reservation.
New manual links use the web project's `APP_URL`. Set the hosted WhatsApp worker's
existing `GUEST_PORTAL_URL` setting to the same hotel app origin, for example
`https://xcloak-hospitality.vercel.app`. The variable name remains compatible with
the existing worker. A separately running Node notification worker should use
that value too.

Existing `?view=food`, `?view=documents`, `?view=bill` and hash-style links resolve
to their focused task. The old guest-domain project now only redirects those links
to the hotel app. Its optional `NEXT_PUBLIC_HOTEL_APP_URL` setting selects the hotel
origin; the existing production app is the default. Keep that old domain while
already-sent links are still in use. New guest tasks require only the hotel app
deployment, the existing Supabase backend, and migration 100. No guest account or
new Meta app/template approval is required for changing the destination page.

Validation: `docs/qa/focused-guest-tasks-2026-11-23.json`.

## Hosted photo-only review

In **WhatsApp Automation → Guest journey**, choose **Hosted photo-only review**.
The Node.js upload-confirmation endpoint downloads the private signed upload,
checks its actual decoded format and dimensions, normalizes orientation, strips
metadata and re-encodes a bounded JPEG using Sharp. Inputs are limited to 10 MB
and 24 megapixels; previews are limited to 3000 × 3000 pixels. PDFs, SVG and
other formats are rejected. A server-side lease makes retries safe.

Staff open only the rebuilt JPEG using the existing permission-checked, audited,
60-second document-access link. The original remains private. `image_ready`
means ready for manual identity review; it is deliberately different from
antivirus `clean` and never writes `scanned_at`. Decode failures become
`image_invalid` and allow a replacement. Temporary failures stay private and
can be retried by the guest or by an authorized staff reviewer. Existing uploaded
JPG/PNG files may be prepared by staff after selecting photo review; existing
PDFs remain quarantined and need a new photo or the antivirus path.

The hotel app needs its existing **server-only** `SUPABASE_SERVICE_ROLE_KEY`.
No third-party document processing service or extra host is required. Run
migrations 101–102 before deploying the updated hotel app. Keep `document-access`
JWT verification enabled.
