# Hotel distribution roadmap

This is a coverage plan, not a claim of live connectivity. Hotels enable channels appropriate to their contracts and markets; they do not need every provider. The Channels catalog includes all requested brands across 24 integration routes and five categories. Repeated brand names are grouped where appropriate; actual contractual coverage must still be confirmed.

## Integration families

| Family | Requested coverage | Integration model / implementation implications |
| --- | --- | --- |
| OTA | Booking.com, Agoda, Expedia, Hotels.com, MakeMyTrip, Goibibo, Yatra, EaseMyTrip, Traveloka | Authorized supplier APIs for availability, rates, restrictions and reservation delivery. Expedia/Hotels.com are one candidate Expedia Group lodging route; MakeMyTrip/Goibibo are one candidate inGo-MMT route. Confirm coverage per agreement rather than counting each logo as an adapter. |
| Rentals and specialist accommodation | Airbnb, Vrbo, Hostelworld, Bedandbreakfast.eu/.nl | Separate partnership checks, inventory model and certification. Dorm bed inventory, entire-home inventory and hotel room types cannot be assumed interchangeable. Vrbo is scoped separately from Expedia lodging even though it is an Expedia Group brand. iCal is not a replacement for two-way ARI/reservation APIs. |
| GDS | Amadeus, Sabre, Travelport (Galileo/Worldspan) | Supplier distribution via agreed CRS / representation route, hotel and chain codes, negotiated/corporate rates and commissions. Travel-agent shopping APIs do not establish permission to publish a hotel's supply. |
| Wholesale | Hotelbeds, WebBeds, Bonotel, GRNconnect, Travco, HPro Travel | Obtain supplier-side contracts and specs. Model net rates, allotment ownership, release periods, payment/credit arrangements and cancellation penalties before availability publication. Do not treat consumer booking APIs as supplier APIs. |
| Metasearch | Google Hotel Ads, KAYAK, trivago, Tripadvisor | Eligible price feeds or query endpoints plus publicly reachable hotel/room/rate landing pages. Accurate taxes/fees, occupancy, currency, availability, click attribution and a complete booking engine are prerequisites for our own direct-booking route. The existing guest stay portal serves booked guests; it is not a public booking engine. |

## Official sources reviewed

- [Expedia Group lodging supply connectivity](https://developers.expediagroup.com/supply/lodging): provider-facing lodging distribution, distinct from Rapid/XAP travel shopping APIs. Brand and Vrbo coverage need explicit confirmation.
- [Google Hotel Prices ARI](https://developers.google.com/hotels/hotel-prices/dev-guide/ari-overview): hotel price/availability feeds. [Delivery modes](https://developers.google.com/hotels/hotel-prices/dev-guide/delivery-mode) explain push/query delivery options.
- [trivago FastConnect](https://developer.trivago.com/fastconnect/fast-connect-overview.html): live availability/price requests to a booking engine or reservation system.
- [Tripadvisor connectivity solutions](https://developer-tripadvisor.com/connectivity/solutions/index.html): Hotel Availability Check and connectivity options. Confirm current commercial program/eligibility with Tripadvisor.
- [WebBeds supplier support](https://www.webbeds.com/suppliers/support/): supported channel-manager / CRS / connectivity-provider routes. [Partner inquiry](https://www.webbeds.com/forms/) for supplier onboarding.
- [Hotelbeds developer portal](https://developer.hotelbeds.com/): public booking/content APIs describe buyer-side capabilities. Obtain the supplier distribution contract separately.
- [Amadeus hotel platform administration](https://webplanning.admin.amadeus.com/online-help/13-3/help13.3/en/76713-hoteladministrationportal_v13.2-generic-en.html) describes central reservation / distribution management. Self-service hotel shopping API access is not supplier certification.
- [Travelport hotel products](https://eportal.travelport.com/pages/HotelProducts.aspx): hotel distribution products; obtain the current supplier agreement and specification directly.

For providers without a verified official wire contract, the catalog intentionally says “to confirm”. No endpoint, authentication scheme or certification status is invented. Current first-three-provider sources are maintained in [channel-manager.md](channel-manager.md).

## Build sequence

1. **Core operational safety:** durable OTA event inbox, stable provider reservation/revision keys, acknowledgement after persistence, recovery polling, multi-room booking transactions, currency verification, conflict queue, scoped room/rate mappings and credential isolation. A local exclusion constraint prevents overlapping local allocations, but cannot prevent all remote overselling.
2. **First OTA pilot:** finish Agoda product discovery, rates/restrictions and reservation lifecycle; acquire sandbox access and certify. Complete Booking.com contracts against approved test machine accounts when access permits; obtain inGo-MMT official partner specs. Existing code implements Agoda product discovery, basic nightly-rate/restriction publication, scoped polling and limited automatic reservation snapshots for sandbox development; Booking.com remains inventory-only.
3. **Inventory and revenue controls:** per-date room/rate calendar, stop-sell, CTA/CTD, min/max LOS, sell limits and safety stock, mapping validation, tax/meal/occupancy models, rate-plan derivation, publish preview, audit, reconciliation and alerts. Include active-room changes and maintenance blocks in availability refreshes.
4. **Broader OTA coverage:** Expedia Group lodging then India/APAC channels according to partner access and pilot demand. Scope rental/specialist channels separately.
5. **Public booking engine and metasearch:** searchable availability, quotes with taxes/fees, expiring room holds, payment workflow, confirmation, cancellation, legal pages and deep links. Then implement Google Hotel Center and other approved metasearch contracts. A guest-portal link does not satisfy this flow.
6. **Wholesale and GDS:** supplier agreements and CRS/representation choice first, then net-rate/allotment/settlement and corporate-rate/commission capabilities. Avoid selling the same committed inventory as unrestricted shared inventory.

This order is an engineering recommendation, not a provider requirement. Commercial onboarding can run in parallel; no external applications or messages are submitted without user instruction.

## What is available now

- Searchable, category-filtered catalog and official references for researched providers.
- Truthful states: availability-only sandbox adapter, awaiting partner contract, planned/not connected.
- Only Agoda, Booking.com and MakeMyTrip have setup forms. No fabricated Connect button for future providers.
- No new distribution backend or provider activation in this catalog update. The previous channel setup migration remains local until approved hosted deployment.
