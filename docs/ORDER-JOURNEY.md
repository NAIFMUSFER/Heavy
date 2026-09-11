# Customer order journeys and password sessions

Web and Expo share `assets/order.js` / `mobile/order.mjs`; an executable equality test allows only the address-module import extension to differ.

Owner onboarding and team entry points are in [the Arabic handoff guide](OWNER-HANDOFF-ar.md). The web operations portal preserves role-permitted section bookmarks across sign-in/reload and warns before discarding an unsaved merchant draft. The launch center only reads existing setup/health endpoints; it does not create an order, activate intake or attest physical operations. Native customer flows are unchanged by this handoff feature.

## History and details

`GET /api/orders?limit=25` returns `items` and `next: {before_at,before_id} | null`. Pass both cursor fields to continue. The service-only database function reads at most limit+1 orders in the authenticated account, ordered by `(created_at DESC,id DESC)` using a customer/time/id index. New orders arriving while browsing do not shift later pages. Legacy offset/next_offset requests remain supported with a bounded offset; new clients use the cursor. Invalid or mixed cursor/offset inputs are rejected.

Clients retain loaded cards on next-page failure, deduplicate overlapping responses, serialize history requests and ignore responses from an ended session. Web has refresh/load-older controls; native uses FlatList with pull to refresh and load older.

Details display frozen delivery address, recipient, building/apartment notes and appointment from confirmed terms. Current line totals and measured quantities remain separate from collected cash, completed refunds and remaining collection. Refunded cash is not a new customer debt; a requested refund is not a completed payment.

After the courier records a real COD collection, the order detail exposes a bounded receipt object derived from the immutable collection ledger entry. Web can download a self-contained printable HTML receipt; native shows its collected time, collected amount, completed refunds and net collection. No receipt appears on delivery alone, and no courier/actor ID or internal settlement reference is exposed. The document states that it is a cash-collection receipt, not a VAT invoice. Later completed refunds update the displayed net amount without rewriting the original collection entry.

The customer timeline contains only ID, whitelisted public event and recorded time. It excludes actors, internal reasons, cash settlement details and delivery codes. The latest 100 public events appear chronologically, with a truncation notice if earlier events exist. Missing events or times do not produce fabricated milestones.

Replacement and whole-line-removal decisions appear in the same order detail on web and native. A removal proposal identifies the unavailable sold line, previous total, exact reduction and total after approval. The line and its reservation remain intact until the owner explicitly approves; rejection or expiry leaves an unresolved picker task. The last remaining line cannot be removed through this flow.

For a fixed multi-component basket, a recorded component shortage may produce a separate component-replacement proposal. It names the missing and replacement components, exact base quantity and common unit, and states that the fixed basket total will not change. No reservation moves before explicit approval. Approval atomically reallocates the exact component and returns the order to picking with all component measurements cleared; the picker must measure the approved composition before finishing. Rejection or expiry preserves the recorded original shortage. This rule does not authorize omitted-component discounts, tolerance bands or variable basket pricing.

## Staff order paging

Staff order lists now use `GET /api/ops/orders?limit=50` with the same paired `before_at` / `before_id` cursor and bounded legacy offset contract. PostgreSQL selects at most limit+1 result rows before JSON aggregation, with time/id and staff task indexes. Admin, finance and support retain complete permitted history; picker and courier lists preserve their existing assignment/claim rules. Delivered work stays on the courier list while collection or remaining cash liability is outstanding, including partial settlement. Existing list RPCs remain for compatibility.

The operations web view shows the number loaded (not a claimed total), offers older pages, retains cards/cursor on a transient next-page failure, deduplicates results and ignores superseded requests or ended sessions. Refresh starts from the current first page. Eligibility can change during browsing as colleagues assign/complete tasks; refresh reconciles that change. This does not change assignments, stock, cash or native customer application behavior.

`tests/operations-orders.py` covers history beyond 100, tied times, new arrivals, compatibility, all permitted staff roles and actual disposable delivery/collection/partial-settlement transitions. The browser journey also exercises a failed staff page and retry on phone width. Exact test/deployment status is recorded in RELEASE-EVIDENCE.md.

## Delivery location and actions

The courier explicitly shares one foreground GPS point using the assigned-order button. The service validates role, assignment, delivery state, coordinates/accuracy and a 15-second per-order limit; it does not run automatically. Tracking exposes a recorded point only for an active outbound delivery, the currently assigned courier and current attempt. Ended/failed journeys and prior drivers/attempts expose no location. Points older than five minutes are explicitly historical; clients show recording time and available accuracy. There is no fabricated ETA or continuous live route. **Automatic courier background location publishing is not implemented**; no location is an honest empty state.

Courier directions use the order snapshot coordinates in an official keyless Google Maps Directions URL. Contact uses a validated Saudi tel: link. Invalid coordinates generate no link. No embedded API, key, billing, phone call or external message is activated automatically.

Native order details include refresh, cancellation while active/queued/unassigned, code renewal during delivery, support, substitutions, refunds and the existing review. Cancellation/renewal require confirmation and authoritative server checks. Renewal invalidates the previous code; the new code stays only in the current screen.

## Launch warehouse ownership

The supported first-market topology is one active launch warehouse. Its owner-entered name, city, operational address and coordinates are private operations data; activation requires all fields and an explicit audited reason. Every delivery zone saved through the operations boundary is linked atomically to that active warehouse, and new delivery slots require the same live route. Existing production zones are not assigned automatically because the application must not guess a real location.

Commercial readiness counts only available slots whose zone belongs to the active warehouse, reports unlinked available slots separately and refuses opening when the route is incomplete. While intake is open the active warehouse cannot be deactivated. This protects the initial single-hub order journey; it does not partition stock balances, FEFO lots or assignments across multiple warehouses. A second active hub remains blocked until that wider model is implemented and accepted.

## Password change

`POST /api/auth/password` requires the current password and the existing cookie CSRF protection. Replacements require at least 12 Unicode characters and at most 72 UTF-8 bytes. The database locks the account, revalidates the session after locking, changes the hash and revokes **every** account session, including the caller. Login already holds a shared account lock, so concurrent login/rotation cannot leave an old-password session alive. Audit metadata contains no credentials.

On success, web cookies and native token/session state are cleared, and the user signs in with the new password. Confirmation is checked locally. A network failure remains an uncertain outcome; the form explains how to proceed if the session ended. Forgotten-password recovery is separate and still requires an approved verified-provider flow.

## Verification and limits

`tests/order-journey.py` runs only against guarded disposable loopback PostgreSQL: more than 100 tied-time orders, new arrivals, ownership, legacy paging, public timeline, assigned/ended/stale/retried positions, UTF-8 boundaries, complete session invalidation and concurrent rotation/login. The finance suite covers absent/pre-collection receipts, exact collection time/amount, refund-derived net values and private helper grants. Node tests cover the shared receipt model, output escaping and actual Edge routes. Browser tests exercise the real downloaded receipt after a separate collection alongside order details, navigation/contact links, recorded/ended tracking, more than 50 orders and two-browser password invalidation through real gateway/Edge/PostgreSQL fixtures. Expo/Android/iOS simulator builds validate compilation; physical-device and operating acceptance remain outstanding.

## Checkout recovery

Web and Expo execute the same `assets/checkout.js` / `mobile/checkout.mjs` controller. A successful quote is saved as an account-scoped ID and attempted-confirmation flag (no address, price, delivery code or credentials in this record). Web uses sessionStorage, surviving reloads in the same tab; native uses SecureStore, surviving process restart on the same device. Explicit logout/password rotation clears the reference. Reinstallation, a cleared browser session and cross-device recovery are not promised; the account order history remains authoritative.

A visible pending-review action reopens the existing reservation before permitting a new quote. Restoration and foreground refresh only read `GET /api/quotes/:id`; they never confirm automatically. The additive quote-detail contract returns authoritative server time and a minimal, ownership-checked existing-order summary, without a delivery code. Clients anchor the expiry countdown to server time using a monotonic timer and refresh the review when the app/tab returns to the foreground. Expired/unknown quotes cannot be confirmed; the customer explicitly releases the reservation or refreshes its outcome. Policy acceptance belongs to the reviewed quote version.

Before confirming, the reference is durably saved. Network/response uncertainty keeps it available and retains the existing transport idempotency key. After restart, an already-created order is recovered by a read, while an uncommitted attempt can be explicitly retried for the same quote. If cancellation races with confirmation, a converted quote displays the existing order instead of claiming cancellation or releasing order stock. A failed recovery read retains the reference and offers retry; an expired authentication session offers sign-in to continue the same account's review.

The cart is cleared only if it still exactly matches the reviewed offering IDs and quantities, and that clearing must persist before acknowledging the reference. Both clients serialize local cart changes and checkout acknowledgement through the shared persistence controller; quote creation waits for pending writes and uses the committed selection. Failed storage writes retain the previous visible quantities and offer retry. Later cart additions remain visible with a notice. A cancelled order is shown in its actual state. Prices/reservations stay server-authoritative; closing the review is not an order or cancellation instruction. An interrupted initial quote creation continues to use the transport retry mechanism when the customer repeats the same selection; a quote without a successfully received ID cannot be discovered through this local reference.

Web tabs on the same browser profile listen for the same-origin cart key and refresh from the persisted value. Browsers that support Web Locks serialize cooperating tab edits under one cart lock; each edit rereads the committed selection inside the lock before applying its quantity change, so simultaneous additions compose rather than silently replacing one another. A damaged external value never replaces the last valid visible cart and exposes the existing explicit retry/reset path. The cart modal and header count repaint after a committed external change.

The revisioned account cart remains an explicit customer action. On another web or native device, the customer chooses either replacement or merge. Merge resolves current catalog versions and prices, combines quantities only for the same stable product family, and rejects the whole local change if an item is unavailable or a stock, per-line or 40-line limit would be exceeded. The merged result is written to that device first; the account copy is not overwritten until a separate explicit save succeeds. Neither restore nor merge creates a quote, order, reservation or delivery booking, and no background cross-device mutation occurs.

Controller, disposable PostgreSQL and browser tests cover restart, server-clock expiry, storage/network failures, lost confirmation responses, same-frame repeated taps, changed carts, same-browser concurrent tab edits, session changes, reference ownership and cancellation/confirmation races. Native builds remain compile/export evidence, not physical-device operating acceptance. See RELEASE-EVIDENCE.md for the current validation and deployment state.
