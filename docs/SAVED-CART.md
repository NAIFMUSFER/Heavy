# Saved customer cart

Customers can explicitly save their current device cart to their account, review the saved copy, restore it on another signed-in browser or mobile device, and clear that saved copy. Local cart persistence remains available offline. These are visible save/restore actions; there is no background cross-device overwrite or automatic merge.

`GET /api/cart` reads only the authenticated customer's cart. `PUT /api/cart` requires a persisted idempotency key, the last reviewed revision and `items: [{offering_family_id, quantity}]`. A new cart has revision zero. PostgreSQL serializes writes by customer, checks the revision and rejects a stale device. Retried identical requests return the original result, even after the revision advances. Changed requests with the same key are rejected. Unknown product families, noninteger or excessive quantities (20 per offering and 40 distinct offerings) are rejected. Browser-supplied names, units and prices are never persisted as commercial truth.

The saved data uses stable sellable lineage IDs. Review resolves the current offering version, price and availability. Retired/unavailable selections remain visible; restoration stops instead of silently dropping them. Both clients re-fetch catalog availability before atomically replacing their local selection. Checkout independently validates and reserves current resources. Saving, clearing or restoring a cart does not reserve inventory, book a slot, create an order or charge money.

Replacing a nonempty saved copy, restoring over a nonempty local cart, and clearing the saved copy require confirmation. The local cart and saved copy remain distinct after checkout; the customer may explicitly reuse or clear the saved copy. Offline/network failures show an error. Mobile PUT retry keys survive application restart in SecureStore. Server saved carts are customer-only, with RLS and service-only RPC execution.

Validation includes concurrent revision races, eight identical retries, customer isolation, current-version resolution and unchanged inventory/capacity. The real browser journey adds saving and restoration through two independent authenticated browser contexts. Signed app/device acceptance remains separate from native compilation.

Migration `20260910092949` is applied and API v20 is active after eleven database cart groups and sixteen browser journey checks passed. The table is initially empty, application RLS covers 41 tables and direct client RPC grants remain zero. Web promotion and current native builds are pending; see RELEASE-EVIDENCE.md.
