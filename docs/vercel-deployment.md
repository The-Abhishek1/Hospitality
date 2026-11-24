# Deploy Hospitality to Vercel

The hotel app now includes focused guest task pages; see [guest tasks](guest-tasks.md). The existing guest-domain project is retained only to redirect previously sent links. New installations need the hotel app, with no separate guest UI deployment. Both existing projects can remain in the same repository; Vercel does not deploy database migrations, Edge Functions or continuous workers.

| Vercel project | Root Directory | Framework | Output Directory |
| --- | --- | --- | --- |
| hospitality-web | `apps/web` | Next.js | `.next` |
| hospitality-guest | `apps/guest-portal` | Next.js | `.next-production` |

Both projects use Node.js 22.x, `npm ci` and `npm run build`. These commands are in each application's `vercel.json`. Retain the committed per-app lockfiles. In the web project's Root Directory settings, enable **Include source files outside of the Root Directory in the Build Step**: secure onboarding imports the shared module in `packages/whatsapp-security`. File tracing includes the repository root. Do not deploy with the repository root as the Next.js app root.

## First deployment

1. Import `The-Abhishek1/Hospitality` into Vercel and set Root Directory to `apps/guest-portal`.
2. Add guest environment variables below and deploy. Record the final HTTPS URL.
3. Import the same repository as a second Vercel project with Root Directory `apps/web`. Enable source files outside the root, set its environment variables, and deploy.
4. Once Vercel assigns the staff URL, set `APP_URL` to that URL and `WHATSAPP_ONBOARDING_ORIGIN` to its origin (no trailing slash or path). Redeploy the staff app. For a stable public address, configure your chosen custom domain in Vercel, then update these values again. Example domain names below are placeholders, not configured domains.
5. Use Production environment variables for the real Supabase project. Avoid giving arbitrary preview branches production backend credentials. Use a separate Supabase project for previews, or disable secure onboarding there.

## Guest project environment

```env
NEXT_PUBLIC_SUPABASE_URL=https://qqqsjvzserjyggcezvac.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=<the current project's legacy anon key>
```

Use the public anon key already configured locally. This is not the service-role key. The guest portal does not need any Meta token, App Secret, encryption key or service-role key.

## Staff project environment

```env
NEXT_PUBLIC_SUPABASE_URL=https://qqqsjvzserjyggcezvac.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=<the current project's legacy anon key>
APP_URL=https://your-staff-project.vercel.app
GUEST_PORTAL_URL=https://your-guest-project.vercel.app
WHATSAPP_APP_ID=962175146725541
WHATSAPP_CONFIG_ID=29826239700301701
WHATSAPP_GRAPH_VERSION=v27.0
WHATSAPP_ONBOARDING_ORIGIN=https://your-staff-project.vercel.app
WHATSAPP_APP_SECRET=<from your private setup file>
SUPABASE_SERVICE_ROLE_KEY=<from your private setup file>
WHATSAPP_ENCRYPTION_KEY=<the existing 64-character hex key from your private setup file>
```

Copy private values locally from `.env.whatsapp-setup` or `apps/web/.env.local` into Vercel's environment-variable form. Do not upload the files to GitHub or put secrets in public variables. Reuse the encryption key on the delivery worker; generating a different key will make stored credentials unreadable. The Meta configuration ID and App ID are intentionally public identifiers. A global WhatsApp access token is not needed on the web project: Embedded Signup exchanges each hotel's code for its authorization.

## Supabase authentication

In Supabase **Authentication → URL Configuration**, set Site URL to the final staff app URL. Add the exact staff callback URL to Redirect URLs:

```text
https://your-staff-project.vercel.app/auth/confirm
```

If you add a custom domain, add its `/auth/confirm` URL too. Keep localhost callbacks only for local development. Verify the current confirmation/password-reset email templates use the app's token-hash callback as described in `docs/local-development.md`; changing the origin does not replace that callback implementation.

Do not reset or reseed hosted data. Migration 77 introduces onboarding sessions, encrypted credentials and permissions. It must be applied to hosted Supabase before using self-service connection setup. The existing hosted Hospitality project has migrations 1–81 recorded as of 2026-11-22. Other deployments should inspect their own migration history before applying updates. A project owner can apply the reviewed `supabase/migrations/20261105000077_whatsapp_embedded_signup.sql` through Supabase SQL Editor, or restore CLI management permissions and use the migration workflow. Do not replay migrations 1–76 on a database where they are already applied. Applying it manually through SQL Editor does not update CLI migration history; reconcile that history before a later `db push`.

## Meta settings after HTTPS is live

In **Facebook Login for Business → Settings**, add the deployed staff hostname to the JavaScript SDK allowed domains and the exact onboarding page URL to the relevant allowed/redirect URI settings. Configure the OAuth/HTTPS toggles according to Meta's Embedded Signup guide. Use the same origin as `WHATSAPP_ONBOARDING_ORIGIN`; leave it without a path in the environment variable.

Example page URL (replace the property ID and domain):

```text
https://your-staff-project.vercel.app/p/<hotel-id>/whatsapp
```

This integration uses the Facebook SDK code callback on that page, not a newly invented `/oauth/callback` endpoint. Keep Meta's WhatsApp webhook pointed to the existing Supabase endpoint:

```text
https://qqqsjvzserjyggcezvac.supabase.co/functions/v1/whatsapp-webhook
```

Do not move that webhook to Vercel. App Review remains required for onboarding independent hotel customers; pre-review tests are limited to the roles/accounts Meta permits. See `docs/whatsapp-onboarding.md`.

## Delivery worker

The scheduled Supabase `whatsapp-worker` and Cron integration now provide hosted event-driven delivery; see [automation deployment](whatsapp-automations.md). Apply migrations 78–81, deploy the function and configure its server secrets and Vault-backed invocation configuration. The following continuous-worker instructions remain an alternative for development or a larger worker pool. Do not enable duplicate consumers unnecessarily.

`services/notification-worker` is a continuously running Node process; a normal Vercel Next.js deployment does not start it. Keep the current development worker running for a temporary test, or deploy it as a persistent worker on a suitable host. Stopping the laptop stops that local worker. The Supabase webhook can still receive messages, but outgoing replies remain queued without a worker.

Build: `npm ci --prefix services/notification-worker` then `npm run build --prefix services/notification-worker`. Start from that directory with `npm start`, supplying server environment variables from the host's secret manager. It needs `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, the shared `WHATSAPP_ENCRYPTION_KEY`, and `WHATSAPP_GRAPH_URL=https://graph.facebook.com/v27.0`. Keep `WHATSAPP_CAMPAIGNS_ENABLED=false`. Existing manual test connections also need their existing `WHATSAPP_TOKENS_JSON` mapping. Securely onboarded connections use the encrypted database credentials instead. The channel-manager service similarly needs its own worker host if enabled; live OTA connections remain subject to provider access/approval.

## Verify after deployment

Sign in, select the hotel and check dashboard/Inbox navigation. Confirm the guest portal opens a legitimate reservation-scoped link, without publishing the link in a repository. After migration 77 and Meta allowlisting, create a separate test hotel for a second number, connect with Meta, send a fresh inbound message and reply from Inbox. Verify disconnect/reconnect retains history and isolates the hotels. A successful Vercel build alone does not establish any provider approval or message-delivery result.

References: [Vercel monorepo settings](https://vercel.com/docs/monorepos/monorepo-faq), [Next.js file tracing](https://nextjs.org/docs/pages/api-reference/config/next-config-js/output), [Meta Embedded Signup](https://developers.facebook.com/documentation/business-messaging/whatsapp/embedded-signup/implementation).

## Hosted confirmation-link configuration

The hosted Hospitality Auth URL settings are tracked separately in
`infrastructure/hosted-auth/supabase/config.toml`. This file declares only the
production Site URL and the hotel app's `/auth/confirm` callbacks, including the
`next` query parameter used by sign-up, confirmation resend and password recovery.
The main `supabase/config.toml` retains the local development URLs.

With Supabase CLI v3, preview and apply this targeted configuration using:

```bash
supabase config diff --remote=qqqsjvzserjyggcezvac --workdir=infrastructure/hosted-auth
supabase config push --remote=qqqsjvzserjyggcezvac --workdir=infrastructure/hosted-auth --yes
```

Confirm that only `auth.site_url` and `auth.additional_redirect_urls` are updated.
Undeclared settings are preserved. Do not push the root local-development Auth
configuration to production: its localhost URLs and local confirmation setting
are intended for the local stack.

After correcting hosted URLs, request a fresh confirmation or recovery email.
Previously delivered emails retain the links they were generated with. See
[Supabase redirect configuration](https://supabase.com/docs/guides/auth/redirect-urls).

## Team invitation emails

Supabase Auth SMTP sends account confirmations and password resets. Team invitations use the Resend API separately; configuring SMTP alone does not configure these application emails.

Set these **server-only** variables on the hotel app's Vercel project, then redeploy:

```env
RESEND_API_KEY=<private Resend sending key for the verified domain>
TEAM_EMAIL_FROM="Xcloak Hospitality <admin@xcloak.tech>"
APP_URL=https://xcloak-hospitality.vercel.app
SUPABASE_SERVICE_ROLE_KEY=<backend-only Supabase key>
```

`TEAM_EMAIL_FROM` defaults to `Xcloak Hospitality <admin@xcloak.tech>` for this installation. Other installations must override it with their verified sender. Use a sending-only Resend key. Never use `NEXT_PUBLIC_` for these keys. The account must have sending enabled for the sender domain. Keep the same stable `APP_URL` as Supabase's allowed authentication callbacks; invitation links go to the app's `/login` and `/signup` pages.

Apply migration `20261105000110_team_invitation_emails.sql` before deploying the UI. Owners and business administrators can create and email property-staff invitations; only owners can email administrator invitations. New invitations and renewed invitations attempt one email send automatically. A failed email preserves the invitation and its role assignments. The invitation page offers explicit resend, manual sharing, and the latest result. The directory shows acceptance and email status separately.

Email records enforce a two-minute resend interval, ten attempts per invitation per day, and one hundred attempts per business per hour. Replayed submissions do not send a second email. Network timeouts and ambiguous provider responses are marked unconfirmed and are not retried automatically. Check the provider logs or ask the recipient before explicitly resending. “Email sent” means Resend accepted the email, not that it reached an inbox; inbox placement, bounces and delivery events remain in the Resend dashboard.

The recipient must use the invited address, confirm their email if requested, then open Today to accept the invitation. Existing accounts use sign-in; no duplicate Auth account is created. Revoked or expired invitations do not grant access, even if their earlier email is opened. Revoking an accepted invitation does not remove a teammate: use Team & access to review or remove membership.

Local testing uses a separate app and a mocked email provider. Never put the real Resend key into the local synthetic-fixture environment. Live email tests require a designated recipient; do not invite arbitrary hotel guests or team members to test delivery.

References: [Resend sending API](https://resend.com/docs/api-reference/emails/send-email), [idempotency](https://resend.com/docs/dashboard/emails/idempotency-keys), [Supabase SMTP](https://resend.com/docs/send-with-supabase-smtp).

Platform administrators can inspect `/api/admin/email-status` while signed in to diagnose missing or invalid invitation-email settings. The endpoint returns setting names only, never their values, and rejects hotel owners and unauthenticated requests. Public Supabase build variables are read directly so Next.js can inline them on Vercel; private email and backend credentials remain server-only runtime variables.
