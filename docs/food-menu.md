# Food menu and ordering

Open **Orders → Food menu → Add menu item**. Add a food photo, name,
food category, dietary classification and optional preparation/allergen details.
Choose **Restaurant**, **Room service**, or **Both**, then choose one price or
add up to 12 individually priced sizes/portions. Save the item as available or
unavailable. Categories such as Starters and Drinks organize dishes independently
of their service destination.

Photos accept JPEG, PNG and WebP up to 4 MB. They are public menu assets, uploaded
through the authenticated hotel app into the separate `food-menu-photos` bucket.
A photo belongs to one hotel; another hotel's item cannot attach it. Keep guest
documents and private photographs out of this public catalog. No Meta template
approval is needed for a food photo on the guest ordering page.

The management catalog defaults to 10 rows per page, with 20/50-row options.
Search and combine food-category, dietary and service filters. Vegetarian results
include vegan dishes. Existing items default to **Not specified** and **Both**;
review their dietary classification rather than assuming old dishes are vegetarian.
Availability and Deleted tabs preserve filters. Editing opens one item at a time.

Staff choose quantities for the required size in the order composer. Guests see
only room-service-eligible items in their personal food helper, choose a portion,
and review the cart before placing an order. Multiple portions of the same dish
can be separate lines. Both views show food photos, dietary labels and prices;
menus are paginated rather than rendering an unlimited list. Existing WhatsApp
food links continue opening this helper.

The database checks hotel ownership, availability, service destination, parent
and size versions, price and tax again when creating an order. Editing an item or
portion preserves existing kitchen and billing snapshots. Changed prices require
a refreshed cart. Guest submissions retain the existing stay authentication,
closed-bill checks, rate limits and idempotent order handling.

**Delete menu item** removes an item from new ordering while preserving past
orders and bills. Expand its confirmation and confirm the action. Restore it from
**Deleted**; it returns as unavailable so the owner can review it before enabling.
Removing a portion similarly keeps historical size and price snapshots.

Migrations 97–99 add the catalog, photo ownership, portions, safe lifecycle actions
and shared authoritative order pricing. They do not reset, reseed or remove
existing hotel records. The hotel deployment needs its existing server-only
`SUPABASE_SERVICE_ROLE_KEY`; never add that key to the guest app. `APP_URL` should
identify the public hotel app origin, including when it runs behind a proxy.

Validation is recorded in `docs/qa/food-menu-2026-11-23.json`.
