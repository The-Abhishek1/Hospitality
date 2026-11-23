# Hotel WhatsApp campaigns

Campaigns use the hotel’s connected WhatsApp account, approved marketing templates and separate marketing permission. Deployment or a saved draft does not prove provider delivery; check each recipient’s delivery status. See `docs/qa/full-flow-2026-11-23.json` for the latest audit results.

## Hotel workflow

Open **WhatsApp Campaigns** from the Management sidebar (`/p/<property>/campaigns`). Hotel administrators/managers with `staff.manage` can:

1. Filter hotel guests by stay period, booking source, reservation status, name or phone. Default: checked-out past guests. For last summer, enter the actual start/end dates. The end date is inclusive; a stay must overlap the period (checkout day does not count as an occupied night). Cancelled/no-show bookings are excluded. Guests whose only bookings belong to another property never enter this hotel's audience.
2. Preview counts and excluded reasons, then choose all eligible matches or manually selected contacts. Selection survives preview pagination; applying different filters clears it. Preview pages contain 30 contacts. Phone numbers require an explicit international `+` country code. Multiple guest records sharing a normalized phone receive at most one message per campaign.
3. Review permission in a separate tab and record actual granted/revoked marketing permission with evidence/source. A previous reservation is not treated as permission. Guest STOP/opt-out and staff-handled/closed conversations override campaign eligibility. Permission records are hotel/phone scoped, append-only and actor/timestamp attributed.
4. Write a custom campaign draft or select an approved marketing template. Save to review, and edit its text/template while it remains a draft. Changing the audience after saving currently requires creating a new draft.
5. Review the exact message, eligibility and contacts, then queue now or choose a hotel-local date/time within the next year. Scheduling freezes the eligible recipients; new matching guests are not silently added later. Counts can change between the live draft preview and scheduling because permission and hotel records are rechecked.
6. Cancel pending/queued work, and inspect individual queued/sending/sent/delivered/read/failed/skipped states and reasons. Reports are paginated; refresh the page for new provider receipts. “Dispatch finished” means no pending/queued/in-flight attempts remain, not that every message was delivered.

The current maximum is 10,000 distinct eligible phones per campaign; manual selection accepts up to 2,000 guest IDs. One-off scheduling is supported. Recurring schedules, pause/resume, campaign cloning and automatic resends of failed campaigns are not implemented.

## Approved content vs drafts

Business-initiated marketing uses approved marketing templates, even for guests who stayed a long time ago. [WhatsApp Business Messaging Policy](https://whatsappbusiness.com/policy/) and [Meta's business chat guidance](https://about.fb.com/news/2025/04/ways-to-manage-your-businesses-chats-on-whatsapp/) describe permission and approved-template requirements.

Our product requires a recorded marketing permission before campaign delivery. Staff can save arbitrary draft copy, but cannot grant provider template approval through the campaign UI. Launch requires an approved **text-only** marketing template from this hotel with exactly matching text. Variables/media/required header or button parameters are not supported in this release. The entire provider definition must be verified before a trusted template-sync/operator process sets `message_templates.campaign_supported=true`; an approved body alone is not sufficient evidence. This flag defaults false. Create and submit templates under **WhatsApp Automation → Templates**, then use **Check approval & sync**. Local draft review is separate from Meta approval.

## Scheduling and delivery

Migrations 73–76 add:

- `whatsapp_marketing_permissions`, `whatsapp_campaigns`, `whatsapp_campaign_recipients` with RLS and active-account policies.
- Private idempotency records for draft saves; case/version checks protect scheduling and cancellation.
- Property-scoped audience, save, permission, launch, cancellation and reporting RPCs.
- A service-only dispatcher that expands due campaigns in bounded batches into the existing inbox queue.
- A V3 queue claim API requiring explicit campaign capability. V1/V2 workers receive only ordinary inbox messages. Existing uncertain-delivery behavior remains: network outcomes that may have sent are not automatically replayed.

Configure a persistent notification worker with `services/notification-worker/.env.example` (Node 22: `node --env-file=.env dist/index.js` after building, or use a process manager). Required server settings remain `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `WHATSAPP_TOKENS_JSON` and a `WHATSAPP_GRAPH_URL` version supported by the configured Meta app. Set **`WHATSAPP_CAMPAIGNS_ENABLED=true`** explicitly to permit due campaign expansion and campaign message claims. It defaults off. Do not start it against a real hotel until its sender, provider approval, permission records and hosted migrations are checked.

Campaign recipient rows are unique by `(campaign_id, wa_contact_id)`. Sender phone ID, body and template name/language are frozen at launch. Dispatcher and pre-send validation check the active tenant, active sender, unchanged approved template, global opt-out, latest marketing permission, staff handoff/conversation state and guest phone identity. Permission withdrawn after scheduling skips recipients; withdrawal after queueing fails the message before provider delivery. A sender/template change blocks or suppresses sending. No guest phone-country guessing occurs.

Cancellation serializes with campaign expansion. It suppresses pending/queued work; validation checks cancellation again after claiming a message. An HTTP request already in flight or accepted by Meta cannot be recalled. Provider messaging limits, throttling, billing and delivery restrictions still apply; scheduling does not bypass them.

Template deletion clears template references while preserving message text. No client delete API exists for campaigns. A trusted permanent campaign deletion cascades its message rows so they cannot become ordinary, less-restricted inbox sends after losing campaign metadata. Tenant teardown is tested with queued test campaigns.

## Verification

- SQL tests cover historical/date filtering, property scope, canonical-phone deduplication, permission/STOP precedence, frozen recipients, timezone scheduling, old worker exclusion, template and sender changes, cancellation, reports and privilege checks.
- Concurrency tests cover repeated draft saves, competing launches, simultaneous dispatchers and cancellation versus expansion, including fixture cleanup.
- Frontend tests cover filter boundaries, pagination and timezone display. Web production build and notification transport tests pass.
- The full-flow audit also checks the browser journey and real template submission/synchronization. Its report separates local provider fixtures from hosted delivery; a campaign draft or queued message is never reported as delivered.
