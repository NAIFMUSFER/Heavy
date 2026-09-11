# Supplier return credit-note reconciliation

This workflow links actual supplier credit-note evidence to an already recorded physical `supplier_return`. It closes the missing document trail between inventory return evidence and finance review without claiming that money reached a bank account.

`GET /api/ops/supplier-credits` provides stable 50-row keyset pages for admin, inventory and finance. Each row contains the supplier return document, item/quantity, the inventory cost removed by that return, all linked credit notes and their total. When inventory cost is known, the UI shows the difference only as a **reference-cost comparison**. A difference is not automatically a receivable, expense, tax amount or accounting error. Unknown inventory cost remains unknown.

`POST /api/ops/disposals/:id/supplier-credits` requires admin or finance, a durable idempotency key, an actually received supplier document reference, positive integer halalas and a reconciliation note. Inventory can review but cannot write. The database verifies the target is a supplier return and that its canonical supplier matches, serializes retries, prevents reuse of a document reference for that supplier, and appends an audit event. Credit notes cannot be edited or deleted.

The workflow does not change stock, reservations, lot cost, order price, customer refund, courier liability or the cash ledger. It does not send a supplier message or create a bank/accounting-provider transaction. Recording an invented or expected document is prohibited; users must record only evidence actually received from the supplier.

Automated verification uses disposable PostgreSQL and browser fixtures only: same-key concurrency, changed-payload conflict, duplicate supplier reference, role isolation, mismatched supplier/database guard, append-only evidence, known/unknown costs, stable pagination, Arabic monetary input and invariance of stock/cost/cash records. Production is checked read-only after application; no supplier credit fixture is created there.

Still required for commercial operations: owner-approved approval thresholds, VAT/accounting classification, evidence-retention procedure, bank or ERP settlement where selected, and actual finance/warehouse acceptance. The system records source evidence but does not certify those business decisions.
