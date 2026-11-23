# Event-driven guest messaging

For the WhatsApp-first booking-to-checkout flow, use [Guest journey setup](whatsapp-guest-journey.md). The legacy portal-led behavior below applies while Guest journey is disabled. Event templates now also support approved text/photo headers and static public URL buttons.

Hotel administrators open **WhatsApp Automation** from the management sidebar or **Templates & automations** in Inbox. This is the live event workspace. Offline message drafts, hotel links and guest menu planning are available under its Advanced section; an offline draft never approves a template or enables sending.

## Hotel setup

1. Connect the hotel's sender through **WhatsApp setup**. A separate test property keeps existing Meta test-number history isolated.
2. Open **WhatsApp Automation → Message templates**. Choose the hotel event, edit the suggested message, select its language and review the sample. Click **Review template**, then explicitly **Submit to Meta for approval**. This creates a template on that hotel's WABA, not a guest message. Only administrators can submit. Operational messages use UTILITY; review requests use MARKETING. Meta decides approval and classification. You can still create templates in WhatsApp Manager.
3. On the same page, click **Check approval & sync**. This refreshes the complete provider directory and never creates templates. Cards show Pending, Ready to use, unsupported format, stale approval or other provider states. Pending submissions do not need resubmission. After a timeout, sync before retrying. Current delivery supports body text with named or numbered variables and an optional static footer. Headers, images, documents, buttons, authentication templates and mixed or invalid variable formats remain unsupported. For scheduled events, the editor creates body-only templates with named fields and sample values. Guest-menu service templates additionally support photo/text headers, footers and static link buttons; see the guest-menu guide.
4. Click **Use for [event]** on an approved template card. In **Event automations**, choose one event at a time, review the sample, map any numbered fields explicitly, choose the timing and enable sending. Changing templates does not silently activate the replacement. Named hotel fields map automatically; numbered placeholders are never guessed. Saving without activation sends nothing.
5. Open **Consent & exceptions** and share the guest’s private stay link through a trusted booking/check-in channel. On the arrival page, the guest chooses updates and optional marketing, then sends a one-time WhatsApp confirmation to prove control of the recorded number. Source, timestamp and proof are recorded automatically. Greetings and unverified preferences alone grant nothing; staff use the collapsed manual fallback for exceptions only. Matching profiles/numbers can reuse the recorded hotel agreement until withdrawal. STOP blocks delivery; review requests require the separate marketing choice.
6. Perform a new action on a dedicated test reservation, then open **Delivery history** and the guest's WhatsApp. Existing past milestones are not replayed. Setup overview identifies the next incomplete step and shows recent worker health.

Example named message: `Hello {{guest_name}}, your check-in at {{hotel_name}} is confirmed. Your personal stay page: {{portal_url}}. Contact reception if you need assistance.` Meta rejects variables at the beginning or end of the body, including variables followed only by punctuation (code 100, subcode 2388299). The editor rejects these locally. Keep written words before and after the variables. This is suggested copy, not provider approval. Keep promotional copy out of operational templates. [Meta template creation reference](https://developers.facebook.com/docs/graph-api/reference/whats-app-business-account/message_templates/).

## Captured milestones

- Reservations: confirmation, date/room changes, cancellation, staff-confirmed check-in and checkout.
- Scheduled stay updates: pre-arrival, checkout reminder and optional post-stay review request. Reminder lead times use the hotel's timezone and configured check-in/out time. The review delay runs after actual checkout when recorded.
- Dining: order placed, preparing, ready, served and cancelled. Walk-in restaurant orders without a reservation are not sent to an unrelated guest.
- Services: guest request received, started, completed and cancelled. Completing a linked service task and its guest request produces one completion notification. Internal housekeeping, maintenance notes, task assignment and unrelated tasks are not guest notifications.
- Billing: recorded payment, refund and issued invoice. These are ledger-recording notifications, not proof of external processor settlement.
- Arrival documents: upload received, review approved or rejected. No document identifiers, scans, internal review notes or private task descriptions are put into messages. Receipt does not imply verification or malware scanning.

There are 23 configurable event types. Events use existing transactional hotel operations; automation does not check a guest in, check them out, accept an order, change a request status, charge a card or approve a document. Feedback, staff administration and OTA synchronization internals do not produce unnecessary guest messages. Live deterministic Hi/Menu replies, links, photos and reception handoff are implemented separately in the [guest menu](whatsapp-guest-menu.md). Arbitrary inbound-question AI remains unimplemented.

## Delivery and suppression

Migrations 78–81 add an atomic domain-event outbox, per-hotel rules/permission evidence, provider template metadata, parameterized queue delivery and the scheduled cloud worker. Only enabled rules capture new milestones. Scheduled reminders are generated for eligible current/future stays; activation does not backfill old milestones. A source-state change suppresses obsolete intermediate updates. Date changes invalidate old reminders. Rule, timezone and hotel-time edits reschedule future reminders while suppressing the obsolete version. Already accepted, delivered or uncertain reminders are not recreated by configuration edits. Room changes within one transaction and linked task/request completion are deduplicated.

Events are held when authorization or configuration is unavailable, up to their expiry (normally 24 hours after their due time). Reminders expire one hour after the hotel's arrival/checkout time. Paused/changed rules, changed source state and expired events are skipped. Permission, phone binding, current sender, template approval/revision/freshness, hotel account status, human handoff and STOP are checked again immediately before sending. A pending/blocked event may become eligible if permission/configuration is supplied before expiry; enabling a new rule does not retroactively create old milestones.

The queue snapshots rendered message text and Meta components. Portal parameters create one cryptographically random, reservation-scoped token when queueing succeeds, with a seven-day expiry. Failed variable validation removes the unused newly generated token. The trusted portal origin comes from the worker's server environment, not a guest-provided link. Guests can use only the actions permitted by their actual reservation status.

Claims carry attempt numbers and database row locks. Overlapping cron invocations cannot claim the same message. Old v1/v2/v3 consumers are fenced out of automation messages so they cannot omit template variables. Explicit provider transient rejections use existing bounded retries. Network timeouts, accepted sends without an ID, worker abandonment and acknowledgment uncertainty are never blindly resent. Disabling a rule cannot recall a request already in flight.

## Hosted scheduler

Supabase Cron invokes `whatsapp-worker` every minute through `pg_net`. The existing hosted Hospitality project has migrations 78–81, this function, and its scheduled configuration deployed as of 2026-11-22; hotel rules remain off until explicitly configured. Its invocation secret is encrypted in Vault; cron SQL contains no service-role key or secret literal. The worker requires that dedicated secret and has JWT verification disabled because cron authenticates with `X-Worker-Secret`. Unauthenticated requests fail. It records a health heartbeat, synchronizes one due hotel's templates per invocation, expands eligible events, then drains bounded single-message claims. Template sync failures back off five minutes; successful sync schedules another in 15 minutes. Template synchronization failure does not prevent other connections being selected on later runs. Many hotels or high volume may require a larger continuous-worker pool; the same queue claim and revision safeguards apply.

Server-only Edge Function environment:

```env
WHATSAPP_WORKER_SECRET=<64 random hexadecimal characters>
WHATSAPP_ENCRYPTION_KEY=<same key as the web app>
WHATSAPP_GRAPH_URL=https://graph.facebook.com/v27.0
WHATSAPP_AUTOMATIONS_ENABLED=true
WHATSAPP_CAMPAIGNS_ENABLED=false # set true only when campaign dispatch is intended
GUEST_PORTAL_URL=https://xcloak-hospitality-guest.vercel.app
WHATSAPP_TOKENS_JSON=<optional mapping for existing manual test connections>
```

Supabase provides `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` to the function. Configure the dedicated invocation secret, project origin and enabled state through service-role-only `configure_whatsapp_cloud_worker`. Keep the web app encryption key and worker key identical. Do not publish these values. The cloud worker also expands and sends due marketing campaigns when `WHATSAPP_CAMPAIGNS_ENABLED=true`. It defaults off and is independent of the automation flag. Campaign permission, frozen recipients, approved-template checks and pre-send validation still apply. This project enabled the flag with the owner’s explicit approval during the 2026-11-23 audit. A review-request rule has its own marketing-consent gate. To stop the scheduler, disable its configuration or pause the cron job; individual hotels pause their rules.

The optional continuous Node worker supports the same event pipeline with `WHATSAPP_AUTOMATIONS_ENABLED=true`, the shared encryption key and trusted `GUEST_PORTAL_URL`. Avoid unnecessary duplicate consumers. Vercel hosts the web UI, not the continuous worker. Use `node scripts/sync-whatsapp-edge.mjs` after changing canonical crypto, template or transport helpers; `--check` verifies the deployable shared copies in CI. Keep standard import formatting in the Edge Function so the CLI discovers its assets.

The scheduled Supabase function lets delivery continue while the development computer is off, subject to the Supabase project's availability and quotas.

## Verification

- `node --test packages/whatsapp-security/security.test.mjs packages/whatsapp-security/templates.test.mjs`
- `npm test --prefix services/notification-worker`
- `npm run build --prefix apps/web`
- `supabase/tests/032_whatsapp_automations.test.sql` on local Supabase, with existing Inbox/campaign/onboarding/security regression suites.
- `python3 supabase/tests/automation-concurrency.py` runs local synthetic concurrent dispatch/claim checks and removes its own fixture.
- Deno type-check of `supabase/functions/whatsapp-worker/index.ts`.

Real delivery still requires a hotel's approved template, recorded permission and a new eligible event. Do not fabricate guest events or change an actual stay just to make a test pass. Use a dedicated test property and an explicitly chosen recipient.

References: [Meta template components](https://developers.facebook.com/documentation/business-messaging/whatsapp/templates/components), [Supabase scheduled Edge Functions](https://supabase.com/docs/guides/functions/schedule-functions).

The legacy Guest messaging workspace is retired. Its URLs redirect to Templates, Event rules or Guest menu & links. Historical draft records remain stored; they are not automatically submitted to Meta. Templates opens a library first; Create template opens a dedicated editor. Approval, event assignment and activation remain separate actions.

## Self-service guest consent (migration 86)

The private stay page’s arrival section collects explicit operational agreement and an independent optional offers/review-marketing choice. It issues a random, hashed, 15-minute challenge tied to the stay, guest, canonical booking phone, active hotel connection and private stay token. The guest sends the prefilled confirmation from that WhatsApp number. Only the service-role webhook can consume it, and it checks the connection, current guest/phone/stay, unrevoked portal link, requested scope, cancellation and expiry before binding the conversation and recording agreement. A greeting or checkbox alone never grants access. No new SMS provider, credentials or unauthenticated verification endpoint is needed.

Only hashes are stored for pending proofs. Five issues per guest/hour are allowed; new challenges replace older ones, cancellation invalidates a pending link without withdrawing existing consent, and provider retries/consumed codes cannot re-grant or duplicate confirmations. Exact agreed message scope, source, timestamp, wording version and inbound-message reference are auditable. Existing guests are not opted in by migration, and historical events are not backfilled. Current blocked events may resume before expiry; normal event eligibility remains enforced.

STOP/UNSUBSCRIBE revoke both scopes and cancel pending proofs. STOP OFFERS/STOP MARKETING withdraw marketing only; STOP UPDATES/STOP STAY UPDATES withdraw operational updates only. A portal holder may withdraw either/both scopes. START alone does not restore the revoked permissions; a fresh explicit verification is required. Delayed consent-confirmation messages are revalidated against authorization version and marketing status before delivery. Human handoff is preserved.

WhatsApp Automation → Consent & exceptions shows paginated guest records, missing/changed numbers, pending confirmations, withdrawals, source and timestamps. Manual verified records are a collapsed staff fallback. Share existing private stay links through permitted booking/email channels or at check-in; the guest controls agreement and the final WhatsApp send. Unknown inbound contacts must obtain their personal link through a trusted hotel channel; a phone match never exposes a booking.

Validation: `037_whatsapp_guest_consent.test.sql`, the WhatsApp/campaign/guest-menu/security regressions, guest portal consent action tests and both production builds. Automated fixtures roll back and do not send real messages. Phone-based end-to-end testing requires a dedicated reservation with the tester’s actual WhatsApp number and their explicit confirmation.
