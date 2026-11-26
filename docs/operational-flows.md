# Room operations, WhatsApp connections and signup

## Bulk room actions

In **Rooms & inventory → Rooms**, select individual rooms, the current page, or **Select all matching rooms** across pages. Filters limit the selection. Choose **Mark clean**, **Start cleaning**, or **Assign housekeeping**, then review and confirm.

One batch supports up to 200 matching rooms. Inactive rooms cannot be selected. Assignment creates or reuses each room's housekeeping task and uses the hotel's cleaning checklist. Mark clean requires inspection; unfinished checklists, multiple open cleaning tasks and linked guest-request tasks remain for individual review. Each room shows its own success or failure, and stale versions must be refreshed. Retrying the same command does not duplicate work.

## Move a WhatsApp number

On the new hotel's **WhatsApp Connection** page, expand **Move a number from another hotel**. Choose the old hotel, confirm, and select **Disconnect old hotel & move here**.

This option requires administrator access to both hotels and an existing secure managed connection. The backend checks Meta authorization and number ownership before moving credentials. A number can be active in only one hotel. Active or uncertain sends and active template setup must finish before a transfer.

Old conversation history stays with the old hotel. Its queued sends and campaigns stop, its automatic rules turn off, and its stored credentials are removed. Guests, consent, old conversations and template assignments are not copied. Configure messaging for the new hotel and test a fresh incoming conversation. The Meta account and phone registration are not deleted or changed.

The move section remains visible when there is no eligible source. It explains whether the connection list failed to load or this login has no qualifying connection. If the hotels use different logins, the old hotel's owner can invite the new login with the **Manager** role for that hotel. Platform administrator access is separate from hotel staff permissions.

Alternatively, disconnect in the old hotel's settings and connect through Meta in the new hotel. A disabled historical connection no longer reserves the phone number. If the old hotel belongs to another owner, ask that owner to disconnect it; the new hotel cannot take it over.

## Signup with an existing email

Confirmed and unconfirmed accounts both show **An account already exists with this email**. Use Sign in, Reset your password or Resend confirmation email. A duplicate signup does not request another signup email or change the existing account. The lookup is restricted to the application backend and rate limited; password recovery keeps its existing generic response.

## Automatic booking welcome

In **WhatsApp Automation → Booking welcome**, assign an approved welcome containing the private document link and switch automatic sending on. At booking, record the guest's prior agreement to receive the one-time welcome on their verified number and its source. This does not grant ongoing stay updates or marketing permission.

An eligible new reservation captures one welcome event. The scheduled delivery worker fills the hotel and stay details, creates the private document-task link and queues the assigned template. Booking or worker retries do not send a second welcome. Turning the rule off prevents future booking events; turning it back on does not backfill old bookings. The reservation's welcome status explains missing permission, setup problems or delivery failures.

### Platform-only permanent hotel removal

Open **Platform admin → Business accounts → a business → Delete hotel permanently** on its hotel card. The review shows aggregate record/file counts without giving the platform administrator access to guest contents. Enter the exact hotel name, a reason and the current platform admin password, then acknowledge irreversible deletion. Existing bookings, historical stays and financial records are included; export required records beforehand.

The backend rechecks platform membership and password before beginning. It freezes the hotel, disables connections and queued work, revokes guest links and removes saved WhatsApp/payment credentials. Active or uncertain deliveries, unresolved payment links, channel syncs, template jobs and document processing block starting the operation. Files (including abandoned uploads and document previews) are removed through Supabase Storage in batches before the database graph is deleted in one transaction. Never use SQL to remove Storage metadata as a substitute for physical file removal. Previously issued upload URLs cannot recreate files while deletion is pending or completed.

If interrupted, reopen the same deletion page and select **Resume deletion**. The hotel stays frozen until cleanup completes. A minimal platform receipt records the actor, hotel identity, reason, counts and completion time. Login accounts, business subscriptions, other hotels and guests with surviving references in another hotel are preserved. Pending staff invitations lose this hotel's grants; invitations left with no hotel access are revoked.

This removes Hospitality's WhatsApp connection, messages, saved templates, automation, campaigns and credentials. It does not delete the hotel's external Meta account/phone registration/templates, OTA listings, merchant accounts or provider transactions. Close external sales and resolve payments with their providers first. The released WhatsApp number can subsequently be connected to another hotel through Meta authorization.

Validation: `supabase/tests/129_platform_hotel_deletion.test.sql` covers permissions, active-work blockers, frozen writes, uploads, ledger/menu/feedback cascades, shared guest isolation, archived hotels and retries. `npm run test:platform` includes route authorization, password verification, trusted Storage manifests and retry behavior. Local browser QA additionally exercises real Storage removal across multiple batches, all four buckets, interrupted cleanup, mobile layout and ordinary-owner denial. No live hotel is deleted by these checks.
