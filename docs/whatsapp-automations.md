# Event-driven guest messaging

Hotel administrators open **Automations** from the management sidebar. This is the live event workspace. **Guest messaging** remains an offline draft/journey planning workspace; reviewing a draft there never approves it with Meta or enables a rule.

## Hotel setup

1. Connect the hotel's actual sender through **WhatsApp setup**. A separate test property keeps the existing Meta test-number history isolated.
2. Create message templates in WhatsApp Manager, submit them, and wait for approval. Use **UTILITY** for operational updates. Post-stay review requests require a **MARKETING** template and separate recorded marketing permission. Template submission is still through Meta, not the local draft editor.
3. In **Automations → Provider templates**, click **Sync approved templates from Meta**. Current support: body text with positional or named variables and an optional static footer. Headers, images, documents, interactive buttons, authentication templates and mixed/invalid parameter formats are not supported by this transport. A synced unsupported template is displayed but cannot be enabled. Synchronization is account-scoped and only commits after the entire provider directory was retrieved.
4. In **Guest permissions**, verify the guest identity and actual WhatsApp number, record their explicit agreement/evidence, and save permission. A phone on a reservation, an inbound Hi, a previous booking, or the portal's existing `stay_updates_requested` preference does not by itself grant verified automation permission. Permission is scoped to that guest profile and hotel, and can cover later stays there until revoked. Guests with shared/duplicate phone profiles require identity review. Staff cannot override STOP by recording this permission. Review requests also require separate marketing permission in Campaigns.
5. In **Event rules**, choose the approved template, map every parameter to a supported event field, set the delay, and enable only the desired milestones. Rules default off. Templates must belong to the hotel's active WABA and have been synchronized within 24 hours. A template definition change requires reviewing/saving the rule again. Parameter fields unavailable for an event block that event instead of sending blank or invented data.
6. Perform a new action and inspect **Delivery history** and Inbox. Pending/blocked events, queueing, sent/delivered/read, skipped events, failures and uncertain outcomes remain distinct. The UI also shows the scheduled worker's latest successful run. No real messages are sent by automated tests.

Example approved check-in body:

```text
Hello {{1}}, your check-in at {{2}} is confirmed. Your personal stay page: {{3}}
```

Map `1 → guest_name`, `2 → hotel_name`, `3 → portal_url`. This is proposed copy, not a claim of provider approval. Other useful fields are `booking_reference`, `check_in`, `check_out`, `hotel_phone`, `room_name`, `event_label`, `order_reference`, `request_title`, `amount`, `currency`, `invoice_number` and `review_url`. Keep promotional copy out of operational templates. Meta determines template classification.

## Captured milestones

- Reservations: confirmation, date/room changes, cancellation, staff-confirmed check-in and checkout.
- Scheduled stay updates: pre-arrival, checkout reminder and optional post-stay review request. Reminder lead times use the hotel's timezone and configured check-in/out time. The review delay runs after actual checkout when recorded.
- Dining: order placed, preparing, ready, served and cancelled. Walk-in restaurant orders without a reservation are not sent to an unrelated guest.
- Services: guest request received, started, completed and cancelled. Completing a linked service task and its guest request produces one completion notification. Internal housekeeping, maintenance notes, task assignment and unrelated tasks are not guest notifications.
- Billing: recorded payment, refund and issued invoice. These are ledger-recording notifications, not proof of external processor settlement.
- Arrival documents: upload received, review approved or rejected. No document identifiers, scans, internal review notes or private task descriptions are put into messages. Receipt does not imply verification or malware scanning.

There are 23 configurable event types. Events use existing transactional hotel operations; automation does not check a guest in, check them out, accept an order, change a request status, charge a card or approve a document. Feedback, staff administration and OTA synchronization internals do not produce unnecessary guest messages. General chatbot/menu replies and arbitrary inbound-question automation are separate features and remain unimplemented.

## Delivery and suppression

Migrations 78–80 add an atomic domain-event outbox, per-hotel rules/permission evidence, provider template metadata, parameterized queue delivery and the scheduled cloud worker. Only enabled rules capture new milestones. Scheduled reminders are generated for eligible current/future stays; activation does not backfill old milestones. A source-state change suppresses obsolete intermediate updates. Date changes invalidate old reminders. Room changes within one transaction and linked task/request completion are deduplicated.

Events are held when authorization or configuration is unavailable, up to their expiry (normally 24 hours after their due time). Reminders expire one hour after the hotel's arrival/checkout time. Paused/changed rules, changed source state and expired events are skipped. Permission, phone binding, current sender, template approval/revision/freshness, hotel account status, human handoff and STOP are checked again immediately before sending. A pending/blocked event may become eligible if permission/configuration is supplied before expiry; enabling a new rule does not retroactively create old milestones.

The queue snapshots rendered message text and Meta components. Portal parameters create one cryptographically random, reservation-scoped token when queueing succeeds, with a seven-day expiry. Failed variable validation removes the unused newly generated token. The trusted portal origin comes from the worker's server environment, not a guest-provided link. Guests can use only the actions permitted by their actual reservation status.

Claims carry attempt numbers and database row locks. Overlapping cron invocations cannot claim the same message. Old v1/v2/v3 consumers are fenced out of automation messages so they cannot omit template variables. Explicit provider transient rejections use existing bounded retries. Network timeouts, accepted sends without an ID, worker abandonment and acknowledgment uncertainty are never blindly resent. Disabling a rule cannot recall a request already in flight.

## Hosted scheduler

Supabase Cron invokes `whatsapp-worker` every minute through `pg_net`. The existing hosted Hospitality project has migrations 78–80, this function, and its scheduled configuration deployed as of 2026-11-22; hotel rules remain off until explicitly configured. Its invocation secret is encrypted in Vault; cron SQL contains no service-role key or secret literal. The worker requires that dedicated secret and has JWT verification disabled because cron authenticates with `X-Worker-Secret`. Unauthenticated requests fail. It records a health heartbeat, synchronizes one due hotel's templates per invocation, expands eligible events, then drains bounded single-message claims. Template sync failures back off five minutes; successful sync schedules another in 15 minutes. Template synchronization failure does not prevent other connections being selected on later runs. Many hotels or high volume may require a larger continuous-worker pool; the same queue claim and revision safeguards apply.

Server-only Edge Function environment:

```env
WHATSAPP_WORKER_SECRET=<64 random hexadecimal characters>
WHATSAPP_ENCRYPTION_KEY=<same key as the web app>
WHATSAPP_GRAPH_URL=https://graph.facebook.com/v27.0
WHATSAPP_AUTOMATIONS_ENABLED=true
GUEST_PORTAL_URL=https://xcloak-hospitality-guest.vercel.app
WHATSAPP_TOKENS_JSON=<optional mapping for existing manual test connections>
```

Supabase provides `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` to the function. Configure the dedicated invocation secret, project origin and enabled state through service-role-only `configure_whatsapp_cloud_worker`. Keep the web app encryption key and worker key identical. Do not publish these values. The cloud worker does not expand or send marketing campaigns; its campaign flag is always false. A review-request rule has its own marketing-consent gate. To stop the scheduler, disable its configuration or pause the cron job; individual hotels pause their rules.

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
