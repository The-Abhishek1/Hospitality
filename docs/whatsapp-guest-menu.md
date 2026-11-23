# Live WhatsApp guest menu

Owners open **WhatsApp Automation → Guest menu & links**. Configure the greeting, enable up to ten options, add hotel URLs and photos, then save with automatic replies enabled. A connected number is required for live delivery. Saving a disabled menu prepares configuration without activating automatic replies. Test by sending a **new** Hi or MENU to that hotel's connected number. New guest messages and manual rich replies wake the cloud worker, throttled to one wake per five seconds. The existing minute cron is the fallback. Nothing backfills old greetings.

Guests receive a real WhatsApp interactive list. Selecting an item sends a CTA link, a photo gallery, a private guest page or a reception handoff acknowledgment. Supported greetings include Hi, Hello, Hey and MENU; commands are case insensitive and tolerate trailing punctuation. After a delivered menu, numbers 1–10 also select the corresponding current option. Repeated greetings within 30 seconds are suppressed. Other incoming text remains for staff; this is a deterministic menu, not a general AI chatbot.

Hotel options include stay details, documents, food, services, check-in/checkout requests, directions, photos, review, website and reception. Up to ten may be enabled. These guest-page actions open the corresponding PWA screen; they never independently check a guest in/out, charge a payment or place an order.

## Public and private content

- Directions, review, website and hotel photos are public. Use valid public HTTPS destinations. Saving updates the shared hotel link settings used by review automations and offline drafts.
- Upload JPEG, PNG or static WebP hotel photos up to 4 MB through the administrator-only endpoint, or paste public image links. Up to five photos can be configured. Each is sent as an image message with an optional caption. External images must satisfy Meta's media requirements. Uploads are public hotel assets: never upload guest IDs or private photos. The server checks staff permission, origin, size and image signatures, generates the storage filename, and keeps the service-role credential server-side. Public gallery storage grants no client write policy. Removing a photo from the menu stops future sharing; it does not delete an already uploaded public object or recall messages already sent.
- Private stay pages require the existing staff-verified guest authorization, conversation binding, matching current phone and exactly one eligible reservation at this hotel. Unknown contacts and ambiguous bookings receive verification guidance. Phone matching alone is insufficient.
- A private page uses the server-configured guest portal origin and a fresh random reservation token, valid for seven days, under `/s/<token>`. No staff-app URL or generic portal homepage is substituted. Navigation uses PWA `view` and `intent` parameters. The browser cannot supply a portal origin. The worker records the trusted origin for manually requested Inbox guest links too.

## Owner and staff replies

The Inbox now offers **Share hotel information** shortcuts for the configured menu, private page actions, directions, photos, reviews and website. These are explicit staff replies and remain available while the automatic menu is paused. All rich replies require an open conversation, an active connection, no contact opt-out and an open 24-hour reply window. The Inbox previews outgoing option lists, images and CTA links with normal delivery status. Incoming option selections show their label rather than only `[interactive]`.

Selecting reception switches on human handoff and queues one acknowledgment. Automatic menu, photo and link replies then remain silent until staff explicitly resumes automation through the existing conversation controls. STOP/UNSUBSCRIBE retain the existing opt-out behavior. START/SUBSCRIBE retain the existing opt-in behavior; a start message does not establish private guest identity or marketing consent.

## Queue and deployment

Migration 82 adds per-hotel menu configuration, a durable inbound-intent queue, rich outgoing snapshots, public hotel photo storage, Inbox shortcuts and previews, and `claim_outbound_messages_v5`. Previous consumers cannot claim rich replies. The updated cloud and Node workers expand menu intents and deliver the validated rich payload through the existing claim/acknowledgment pipeline. Provider timeouts and unknown outcomes are never blindly retried.

Window expiry, opt-out, connection/sender changes, configuration revision, guest authorization, reservation eligibility and automatic handoff state are checked again before delivery. Configuration changes invalidate queued old-menu snapshots. Enabling a menu does not replay messages received while disabled. Each provider message and generated reply is deduplicated. A setting change cannot recall a provider request already in flight.

This feature implements interactive **service-window replies**. Scheduled/event notifications still use the approved body-only template transport. Image headers/buttons in proactive templates and arbitrary conversational AI remain separate work; the offline draft designer does not activate those capabilities.

Validation: `supabase/tests/033_whatsapp_guest_concierge.test.sql`, existing WhatsApp/Inbox/campaign/onboarding/automation/security regressions, `npm run test:concierge --prefix apps/web`, worker transport tests, Edge helper consistency, Deno check and the production web build. End-to-end phone delivery requires the owner to enable the menu and send a new message; automated tests use synthetic local conversations, never actual hotel guests.

References: [Meta list messages](https://developers.facebook.com/documentation/business-messaging/whatsapp/messages/interactive-list-messages), [CTA URL buttons](https://developers.facebook.com/documentation/business-messaging/whatsapp/messages/interactive-cta-url-messages), [image messages](https://developers.facebook.com/documentation/business-messaging/whatsapp/messages/image-messages).
