# COD and refund integrity

The previous settlement subtracted every completed refund from courier liability. That was incorrect when JANA finance paid the refund from company funds. The old admin refund also recorded completion without a real payment reference. Customer refund requests depended on component identifiers that order snapshots do not contain. The tested correction is applied; complete commercial acceptance is still outstanding.

Migration `20260910030745` enforces:

- Customer requests reserve refundable money and do not claim a payment occurred.
- Completed refunds require an authorized finance/admin actor, reason, explicit payment source, and the actual payment reference.
- A courier-funded refund reduces that courier's recorded cash liability. A finance-funded refund leaves courier liability unchanged.
- Liability equals collected cash minus finance settlements minus refunds paid from courier cash.
- Settlement can be partial; each amount and reference is retained in an append-only cash ledger.
- One order row serializes collection, refund completion, and settlement. Deferred ledger checks reconcile account totals before commit.
- Replayed idempotency keys return the recorded original result. A reference cannot be counted twice for the same order/event type.
- No money is transferred by these COD recordkeeping APIs. Staff must confirm a payment actually occurred before recording it. Online payment/refund integration requires a selected provider, implementation and owner-approved configuration.

Production pre-migration evidence, 10 September 2026: one existing order; zero collected orders, zero courier-held cash orders, zero refund records. No historical refund source needs to be invented. The migration is applied with zero cash-ledger mismatches and unchanged original order snapshots.

The first disposable PostgreSQL financial run (34431555191) passed sixteen financial groups, then failed on an ambiguous SQL alias in the overview report. The alias was corrected; the complete gate passed in run **34431933621**, including seventeen financial groups. API v15 and operations v12 are deployed. Web/mobile financial UI and service-worker update release are pending verification.
