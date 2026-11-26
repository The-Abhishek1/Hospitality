# Room prices by date

Open **Rooms & inventory → Room types & rates → Date pricing**.

1. Choose a room type. Prices apply to every room of that type.
2. Choose the first and last overnight dates. The last night is included; a guest checking out that morning does not pay for that night.
3. Select all days, weekdays, weekends, or individual weekdays.
4. Enter the price **per room per night**, optionally label the period, review the selection, and save.

For example, select December 7–13 and enter ₹5,500 to price those seven nights at ₹5,500 each. Set December 14–20 separately for the following week's price. Applying another price to overlapping nights replaces only the selected dates and weekdays.

The calendar shows fourteen nights and ten room types at a time. Custom prices are blue. Click a future calendar cell to edit a single night, or use the date and room-type filters. **Use the base price again** removes overrides for the selected nights. Past nights cannot be edited; updates cover at most 366 nights, up to two years ahead in the hotel's timezone.

Room-type base prices cover dates without overrides. Rate-plan discounts or premiums apply after the date-specific price. New reservation quotes show the nightly breakdown. Direct bookings, returning-guest bookings, walk-ins, and group bookings use the same pricing calculation.

Existing reservations keep their agreed total. New bookings also save each agreed nightly amount, so billing and night audit post the booked price for that date even after a calendar change. Explicitly amending an unbilled reservation requires accepting a fresh quote. Bookings predating this feature keep their existing agreed-total billing behavior. Channel reservations retain their supplied agreed total; this calendar does not push prices to OTAs.

Inventory management access is required to edit prices. Saves are audited and reject stale calendar versions; booking confirmation rejects stale quotes. Refresh and review before resubmitting if another staff member changes prices.

Local validation:

```sh
npm --prefix apps/web run test:inventory
supabase test db supabase/tests/124_date_based_room_pricing.test.sql
python3 supabase/tests/pricing-concurrency.py
```

The concurrency script permits only a loopback database and removes its synthetic test records. Do not run database tests against a hotel's production data.
