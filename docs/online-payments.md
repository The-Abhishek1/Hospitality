# Hotel checkout payments

This release supports **Razorpay Test Mode only**, with separate encrypted merchant credentials for each property. It does not enable live payments, Razorpay Route settlements, WhatsApp Pay or partner OAuth onboarding. Razorpay hosts the payment form; card details never enter Hospitality.

## Hotel setup

1. Create or select a **dedicated test hotel**. Synthetic payments settle its folios and can permit checkout without collecting real money. Do not connect a real operating property's accounts to Test Mode.
2. Open **Billing → Online payments**. Enter that hotel's Razorpay Test Mode Key ID (`rzp_test_…`) and Key Secret. Confirm the test-hotel declaration and connect. Only a hotel administrator can configure credentials; billing staff can request and reconcile payments.
3. In Razorpay's Test Mode webhook settings, copy the URL and generated webhook secret from this page. Subscribe to `payment_link.paid`, `payment_link.expired`, `payment_link.cancelled`, `payment.captured`, `payment.failed` and `refund.processed`. Use the public HTTPS hotel-app deployment.
4. Turn on **Online checkout in WhatsApp**. Enable the hotel's WhatsApp guest journey and ensure the guest's number and stay-update agreement are verified.
5. On an in-house test stay with an INR balance, send **Checkout** from the verified guest's WhatsApp. Alternatively, open the stay's folio and create a Test Mode payment link; select the WhatsApp option to send it in an open reply window.
6. Complete Razorpay's test payment using test details. Payment verification records the collection once and refreshes the folio. WhatsApp sends a receipt and **Confirm checkout** when the current balance is zero. Confirmation rechecks the bill and unfinished food orders, checks the guest out, marks the room dirty and creates a cleaning task.

Being paid does not automatically vacate the room. Extra charges after link creation remain due; an obsolete unpaid link is cancelled before preparing a replacement. If payment succeeds while the bill changes, the actual captured amount is recorded and the remaining balance must be settled.

## Platform deployment

- Apply migration `20261105000114_hotel_online_payments.sql`.
- Deploy `payments-worker` with JWT verification disabled; it authenticates using `X-Worker-Secret`.
- The web app and Edge worker use the **existing** `WHATSAPP_ENCRYPTION_KEY` (64 hex characters). Payment credentials use a separate connection-bound encryption context (`razorpay:<connection-id>`). `PAYMENTS_ENCRYPTION_KEY` may explicitly override it, but must match on both servers. Changing the key requires reconnecting existing accounts.
- The worker uses the existing `WHATSAPP_WORKER_SECRET`. `PAYMENTS_WORKER_SECRET` is an optional override and must match the configured database worker secret. The standard setup reuses the existing Vault-backed WhatsApp worker configuration.
- Call the service-only `configure_payment_cloud_worker(true)` after deployment. This enables a dedicated serverless cron every minute; no separate worker server is required. The configuration RPC needs an existing WhatsApp cloud-worker origin and Vault secret.
- Vercel needs `APP_URL`, `SUPABASE_SERVICE_ROLE_KEY`, the existing Supabase public variables, and the encryption key above. Never expose merchant secrets in `NEXT_PUBLIC_` variables or commit them.

## Accounting and recovery

Signed webhooks only schedule reconciliation. The worker fetches the payment link and captured payment from Razorpay with the **same hotel's credentials**, verifies the request reference, amount, currency, order and hotel/stay binding, and then posts a unique ledger payment. Redirects and unsigned client requests cannot mark bills paid.

Leases and unique references prevent concurrent workers and webhook retries from duplicating money or receipts. After an uncertain create response, the worker looks up the original reference instead of issuing another POST. If that creation cannot be confirmed, the request remains blocked for review; a local timeout alone does not cancel a possibly paid link. Manual collections are blocked while an online link is unresolved.

Use **Check payment status** to request reconciliation or **Cancel link** to request provider cancellation. Wait for confirmation before collecting another payment. Pause stops new requests; existing links still reconcile. Disconnect and replacement require open requests to be resolved first, and preserve historical webhook verification.

Issue online refunds in Razorpay. A processed refund webhook triggers provider verification and records the refund once. The hotel's manual refund form cannot claim that a Razorpay refund was issued. A refund changes the folio balance and may require a credit adjustment under the existing billing rules; it never checks a guest back in.

The native payment-link/receipt replies respect guest identity, opt-out, human handoff and the WhatsApp 24-hour reply window. If the window closes before confirmation, the folio still updates; the guest can send Hi again and request checkout, or staff can use approved event templates configured for the hotel.

## Verification

- `node packages/razorpay/razorpay.test.mjs`: provider request contracts, uncertain outcomes, cancellation, captured payments and account/amount checks with synthetic responses.
- `supabase/tests/114_online_payments.test.sql`: transactional accounting, permissions, duplicate notifications, refunds, WhatsApp checkout and housekeeping.
- A real Razorpay Test Mode checkout still requires the hotel's private test keys and webhook configuration. Synthetic transport tests do not establish real-provider connectivity.

Provider references: [Payment Links](https://razorpay.com/docs/api/payments/payment-links/create-standard/), [webhook validation](https://razorpay.com/docs/webhooks/validate-test/).
