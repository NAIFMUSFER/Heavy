# Physical customer and courier returns

Status: 189 JavaScript tests, 22 PostgreSQL groups and 33 browser checks passed on source 86940a5. Migration 20260910170206 is applied; customer API v25 and operations Edge v20 are active. Gateway promotion is pending. Production receipts and inspections remain zero; existing order, stock and lot fingerprints are unchanged.

Admin/inventory staff look up the exact order number and select an actual shipped stock/lot allocation. Only delivered shipments or failed deliveries after completed picking are eligible. The operator records the quantity physically received, a real receipt reference and the reason. The canonical stock, unit, lot, order and actor are resolved by PostgreSQL; they cannot be selected through arbitrary client names or prices.

The receipt is quarantined outside usable on-hand and reserved balances. Its immutable original source and quantity are recorded, with an audit and a zero-usable-delta stock movement. A source/document uniqueness rule and persisted request idempotency prevent repeat receipt. Concurrent receipts serialize against the original order and movement, and all received quantities, including rejected and pending returns, count against the quantity actually shipped.

A separate irreversible quality inspection records accepted and rejected quantities plus the observation/reason. The accepted amount starts blank in the UI. Staff explicitly confirm the real decision. PostgreSQL locks the stock balance, source movement and original lot, permits one immutable decision, and checks current expiry. Only the accepted quantity re-enters the original accepted, unexpired lot; expiry is never renewed. Rejected returned goods remain physically segregated and unavailable for sale. A separate physical disposal/custody-close workflow for rejected returns is still required; rejection does not claim destruction or decrement usable stock a second time.

Accepted stock restores its original shipment cost with cumulative rounding capped at the original consumption value. Known zero, recorded, estimated and unknown source costs remain distinct. Missing source cost is never replaced with the current retail price. Mixing unknown returned cost into existing stock conservatively marks the pooled lot cost unknown; immutable individual cost events remain available. The positive cost entry references the original order so operational net COGS reflects the return. Order prices, COD collection, courier liability, settlements and refunds are unchanged. A financial refund is a separate reviewed workflow.

The original failed order cannot be redispatched once its physical goods have been received back, even while inspection is pending. Receipt and redispatch serialize on the order. A new approved replacement order requires a new quote/reservation; returned goods cannot silently be delivered twice. There is no automatic replacement or customer charge.

Admin/inventory can receive and inspect; finance reads cost evidence; support reads return status with purchase cost redacted. No customer/courier write API is exposed. History uses 50-row stable keyset pages and displays pending/inspected/rejected receipt counts without summing grams and pieces together. The general movement ledger resolves actual return document references.

API:

- `GET /api/ops/customer-returns/context?number=...` — exact original shipment allocations; admin/inventory.
- `POST /api/ops/customer-returns` — physical receipt; requires Idempotency-Key.
- `POST /api/ops/customer-returns/:id/inspection` — accepted quantity and quality observation; requires Idempotency-Key.
- `GET /api/ops/customer-returns?before_at=...&before_id=...` — paginated history; role-filtered cost evidence.

Migration: `20260910170206_jana_customer_return_inspection.sql` (applied; unchanged SQL renamed to the actual migration version). The two new application tables have RLS and no client-role grants. Application RPCs are service-only with server-side JANA session/role checks. The order redispatch trigger helper is not callable by API roles. This migration does not modify PostGIS objects or backfill historical order/inventory values.

Remaining operations: owner-approved quality/food-handling and return policies, actual warehouse acceptance, rejected-stock physical disposal/custody closure, a dedicated canonical warehouse/location model, and supplier financial credits. The return UI does not certify a food safety policy or invent observed quality.
