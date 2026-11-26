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
