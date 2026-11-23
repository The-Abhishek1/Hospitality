# Closing and reopening a property

Business owners use **Manage properties → Close & archive** or **Property settings → Review closure & archive**. Administrators can review; only the owner confirms. The confirmation requires the exact hotel name, a reason and acknowledgement that sales have been closed in external booking systems.

Closure requires all confirmed/in-house stays and unfinished food orders to be resolved. In-flight WhatsApp delivery, outbound channel synchronization and channel polling block closure until finished. Open folios are highlighted for review. Archiving is not an OTA stop-sell request: the owner must close external listings/sales first.

Archived hotels leave the active hotel switcher. Owners and business administrators retain read-only reservations, billing and reports through the Archived tab; ordinary assigned staff lose access. Operational table guards also reject backend booking/order writes against closed hotels. Direct authenticated property deletion is disabled to protect the related history.

Closure disables the WhatsApp connection, deletes managed credentials, invalidates onboarding sessions and guest links, cancels unconsumed consent proofs, disables event rules and automatic menus, cancels scheduled/running campaigns, and cancels queued outbound messages and channel jobs. Channels pause. Other hotels are unaffected. A provider call already in flight must settle before closure can proceed.

**Archived → Review & reopen** restores an active property slot subject to the plan cap. It does not revive campaigns, old events, credentials, guest links, channel connections or automation. Review rooms/rates, reconnect the sender, issue fresh links and explicitly enable integrations. Archiving frees active property capacity; it does not automatically change subscription charges.

Migration 87 records closure/reopening actor, reason and time. Existing hotels remain active. Test `038_property_closure.test.sql` uses synthetic fixtures and rolls back; never archive a real hotel just to test deployment.
