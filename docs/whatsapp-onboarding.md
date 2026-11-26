# Hotel WhatsApp onboarding

The `/p/[propertyId]/whatsapp` page uses Meta Embedded Signup v4 for Cloud API numbers and existing WhatsApp Business app numbers through Coexistence. Existing test/manual Inbox connections remain supported. Coexistence includes contact and permitted chat-history imports; migration from another provider is a separate flow. Do not disconnect/delete a hotel's mobile account to force eligibility.

## Meta setup by the platform owner

1. Open Hospitality in Meta Developers. Complete **Become a Tech Provider**, including the access-verification tasks Meta displays. Business verification is separate from Tech Provider approval and App Review.
2. In **Facebook Login for Business → Configurations**, create a **WhatsApp Embedded Signup** configuration and select **Cloud API**. Use the configuration's selected permissions; obtain Advanced Access for `whatsapp_business_management` and `whatsapp_business_messaging`, and any additional permissions you choose. Copy the configuration ID.
3. Host the application at an HTTPS origin. Add that origin/domain and exact onboarding page URL to the appropriate allowed-domain and OAuth redirect settings. Enable the JavaScript SDK and the OAuth/HTTPS settings specified by Meta. Plain localhost HTTP cannot complete signup.
4. Configure the app's WhatsApp webhook with the existing Supabase function URL and matching verification token. Subscribe `messages`, `account_update`, `history`, `smb_app_state_sync` and `smb_message_echoes`. The webhook handles messages, statuses, Coexistence imports and signed account-removal events. Completion uses verified API asset discovery.
5. In App Review, provide actual reviewer instructions, an accessible review account, privacy policy and data-deletion information, and a video demonstrating hotel authorization, receiving/replying and disconnection. Do not claim approval from a successful developer-role test. Only publish after reviewing the production requirements shown by Meta.

Meta links:
- https://developers.facebook.com/documentation/business-messaging/whatsapp/embedded-signup/implementation
- https://developers.facebook.com/documentation/business-messaging/whatsapp/embedded-signup/version-4
- https://developers.facebook.com/documentation/business-messaging/whatsapp/embedded-signup/onboarding-customers-as-a-tech-provider
- https://developers.facebook.com/docs/development/release/tech-providers/

Public app URLs for Meta **App settings → Basic**:
- Privacy Policy URL: `https://xcloak-hospitality.vercel.app/privacy`
- User data deletion: choose **Data deletion instructions URL** and enter `https://xcloak-hospitality.vercel.app/data-deletion`. This page is an email-based request process, not a signed-request callback endpoint.

Both pages are accessible without a staff account. The guest deployment serves the same policy and instructions. The privacy contact is `admin@xcloak.tech`; requests need to be reviewed and handled by Xcloak and the responsible hotel. Publishing a policy does not automate record deletion or establish Meta approval.

## Server configuration

Apply migration 77 before using the page. Configure these **server-only** values in the web application:

```env
WHATSAPP_APP_ID=<current Meta application ID>
WHATSAPP_APP_SECRET=<current app secret>
WHATSAPP_CONFIG_ID=<Embedded Signup Cloud API configuration ID>
WHATSAPP_GRAPH_VERSION=v27.0
WHATSAPP_ONBOARDING_ORIGIN=https://your-hospitality-domain.example
WHATSAPP_ENCRYPTION_KEY=<64 hexadecimal characters from 32 random bytes>
SUPABASE_SERVICE_ROLE_KEY=<backend Supabase key>
```

Configure the **same encryption key** on the notification worker and set its `WHATSAPP_GRAPH_URL` to the same Graph version. Preserve this key in a secret manager with access controls and backups; losing or changing it makes existing authorizations unreadable. Rotation requires re-encryption or hotel reconnection. Never put these secrets in `NEXT_PUBLIC_` variables. App/config IDs are passed to the browser intentionally; tokens and app secrets are not.

Credentials are AES-256-GCM encrypted with the hotel reference as authenticated data. Ciphertext lives in a private database table, accessible through a service-role-only retrieval RPC for active connections/tenants. The browser uses a short-lived one-attempt session bound to the signed-in hotel administrator. The backend verifies the number belongs to the account using the exchanged token, registers new connections using the user's PIN, subscribes the app, then commits credentials atomically. External Meta operations cannot be rolled back if the final database commit fails; retry onboarding and retain the number's existing PIN. PINs are not stored. Tokens are not cached by the worker.

Both standard Cloud API setup and WhatsApp Business app Coexistence are supported. Cancellation/failure does not activate a new connection. Existing sender IDs cannot be replaced, including through legacy manual RPCs. To test another sender, create a separate test property. A phone ID can belong to only one property. Disconnect disables local inbound/queue handling and removes the stored token; it retains history and does not revoke Meta-level partner access. Owners can remove that access in Meta Business Settings. A message already in transit cannot be recalled. Reconnect authorizes the original sender again.

Health checks read Meta phone ownership and app subscription; they do not imply delivery, template approval, unrestricted account status, or billing readiness. Campaigns remain explicitly disabled unless separately enabled after review. New hotels require their own approved templates; the configuration does not copy another hotel's templates or authorize marketing consent.

## Second-number test

1. Start the web app at its approved HTTPS origin and start the rebuilt notification worker with the shared encryption key. Use a Meta app admin/developer for pre-review testing where Meta permits it.
2. Create a separate test hotel, open **Property settings → Guest conversations** or **Inbox → Connection setup** and launch signup. Enter/retain the number's six-digit two-step PIN, then complete Meta authorization and click Finish.
3. Check connection health. Send a unique message from a different personal test phone. Confirm it appears only in the selected hotel's Inbox; reply and check provider delivery status.
4. Disconnect, verify credentials are no longer available and new replies are blocked, then reconnect the same sender and retest.
5. Test a second hotel's administrator cannot read/manage the first hotel's setup. Avoid fake incoming events in the hosted database.

Automated checks: `node --test packages/whatsapp-security/security.test.mjs`, notification-worker `npm test`, web `npm run build`, and local database `031_whatsapp_onboarding.test.sql`. Provider account approval and real browser signup require Meta account access; mocked checks cannot establish them.

## Existing WhatsApp Business app numbers (Coexistence)

Apply migrations 122–123 and deploy `whatsapp-webhook` and `whatsapp-coexistence-worker`
before deploying the hotel UI. The new worker uses the existing shared
`WHATSAPP_WORKER_SECRET`, `WHATSAPP_ENCRYPTION_KEY` and Graph URL. The migration
reuses the existing Vault-backed scheduler; it does not introduce another server,
copy plaintext credentials or change the encryption key.

In Meta, keep `messages` and `account_update` subscribed and also subscribe to
`history`, `smb_app_state_sync` and `smb_message_echoes` on the app's
`whatsapp_business_account` webhook subscription. Business verification alone
does not grant Coexistence: complete Tech Provider onboarding, App Review /
Advanced Access and any Access Verification requested by Meta. The error saying
the partner app is not set up to connect Business app numbers is a Meta-side
eligibility/setup failure. Selecting a launch feature cannot grant that access.

Hotel flow:

1. Open **WhatsApp Connection → Keep using WhatsApp Business app**.
2. Enter the existing number with its country code. The app binds this number and
   connection type to the server-side setup session before opening Meta.
3. Continue with Meta. The launch uses the v4 login configuration with
   `featureType: whatsapp_business_app_onboarding` and session-info version 3.
4. Complete verification inside the WhatsApp Business app and choose whether to
   share past chats. No deletion, deregistration or new two-step PIN is requested
   by Hospitality for this path.
5. The backend accepts `FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING`, including its
   WABA-only variant. It discovers the exact authorized number, verifies
   `is_on_biz_app=true` and `platform_type=CLOUD_API`, subscribes the app, and saves
   the encrypted connection. It never calls `/register` for this path.
6. Keep the phone app open. Contacts and permitted history are requested promptly
   through the single-use SMB App Data API, within Meta's 24-hour start window.
   The status card shows request outcomes, progress, imported counts and errors.

New phone-app messages appear as **Phone app** in Inbox; imported conversations
are labeled **Imported history**. Old chats start resolved, accessible with the
Inbox's All/Resolved filter. Recent phone-app replies switch the conversation to
human handling and cancel queued automatic replies. Resume automation explicitly
using Inbox's conversation controls. An echo of an already recorded provider ID
does not create a duplicate or silently change an API message's source.

History and contacts are imported in durable, resumable batches of up to 200
records. Retries deduplicate by connection and provider message ID. No imported
message runs Hi/menu commands, binds a guest identity, grants consent or opens a
Cloud API customer-service window. Fresh guest messages still use the existing
consent and verified-identity flows. Contact imports do not create hotel guest
records or campaign audiences. Phone-less identities are retained privately for
support rather than guessed or sent to another guest. Photos and other media are
represented by their captions/placeholders; automatic media downloading is not
implemented. Late history media details, edits and deletions update their original
messages without replaying guest actions.

Single-use requests with a timeout or uncertain response are **not** resent
automatically. A received completion webhook can resolve an uncertain result.
Only definite request rejections can be retried explicitly while the window is
open; failed local import batches can be retried safely. Declining history sharing
is recorded as a normal choice. Local reconnect does not request the same import again. Verified re-onboarding after a signed Meta offboarding event starts a new import cycle while preserving recorded messages.
Signed account-removal/offboarding events disable the affected account's local
connections and remove stored credentials; older pre-connection events cannot
disable a newer connection.

Validate with `122_whatsapp_coexistence.test.sql`,
`packages/whatsapp-security/coexistence.test.mjs`,
`apps/web/tests/coexistence-onboarding.test.mjs` and
`apps/web/tests/coexistence-webhook.test.mjs`. Real-number onboarding and message
mirroring still require Meta's approval and an eligible WhatsApp Business app
account. Do not claim that a simulated completion establishes either.

Reference: [Meta's Coexistence implementation guide](https://developers.facebook.com/documentation/business-messaging/whatsapp/embedded-signup/onboarding-business-app-users/).

## Automatic hotel message setup

After connecting a hotel's WhatsApp number, open **WhatsApp Automation → Overview**. Save the hotel's HTTPS location and Google review links, select 3–4 uploaded hotel photos, then choose **Prepare all default messages**. The hotel app rebuilds these into one welcome collage. Website is optional; its default menu service stays disabled until configured.

A serverless setup queue submits a versioned pack of 25 event templates and 12 menu-service templates, four new templates per run. Names include the full property UUID, so hotels sharing a WABA cannot collide. Lookup precedes every creation, including retries after an uncertain provider response. Provider approval is never assumed. Each hotel sees progress and any rejected/unsupported/category-mismatched templates.

Turn on **Default automation** when ready. Approved event templates activate automatically and the default grouped menu publishes when its menu templates are ready. Individual owner-edited rules and owner-edited menus are preserved. The master switch also blocks custom automatic messages and native guest replies; manual Inbox replies remain available. Switching off cancels queued automatic messages, and activation does not replay old hotel events. The separate marketing review reminder is assigned but stays off to avoid duplicating the checkout thank-you.

Booking welcome contains the collage, directions and a reservation-specific document-upload link, and still requires prior booking-contact permission. Ongoing stay updates and marketing remain separate guest choices. Checkout thanks includes the configured review button; Meta must approve the submitted category. The explicit Hotel photos menu service may also show the collage on request; routine order, service and document messages do not attach hotel photos.

Food feedback follows delivery by 20 minutes; service feedback follows completion by 5 minutes. Guests reply **RATE FOOD** or **RATE SERVICE**, choose the completed item and rate it in WhatsApp. An optional next text comment is attached to that rating for 15 minutes. One rating is accepted per completed order/request/stay; replayed or foreign-conversation buttons cannot submit another rating. See **WhatsApp Automation → Guest feedback** for ratings and links to the corresponding records.

After checkout, Hi/Hello/Menu opens a post-stay menu with bill/receipt, stay feedback, an honest-review link, lost-item/support, new booking enquiries and reception. Verified active/upcoming stays take priority; ambiguous bookings go to staff. Secure bill links last 24 hours. Old operational actions do not reopen a stay, place orders or bypass check-in checks. Existing consent, STOP, human handoff, archived-property and reply-window guards still apply.

Use **Customize template** to submit a newly named replacement. Keep the old template until review finishes. Compatible event and menu assignments switch after approval; incompatible replacements show a reason and retain old assignments. No Meta delete is required.

Platform deployment: apply migrations 116–119, deploy `whatsapp-setup-worker` with JWT verification disabled, and set its shared `WHATSAPP_WORKER_SECRET`, `WHATSAPP_ENCRYPTION_KEY`, `WHATSAPP_APP_ID`, Graph version and any existing manual-token mapping consistently with the delivery worker. The existing Vault-backed WhatsApp worker configuration authenticates the setup cron. No separate server is needed. Existing hotels are not bulk-submitted until an administrator completes their setup; new WhatsApp connections automatically receive the local setup registry.
