# Release evidence — 10 September 2026

This is an engineering checkpoint, not a commercial launch certification.

| Evidence | Verified result |
|---|---|
| Render gateway commit 92850d3 | Live; complete verification and smoke succeeded in Actions run 34397238501 |
| Render gateway commit 44760b5 | Deployment dep-dagrn6mq1p3s738l6ajg is live; complete verification and smoke passed, run 34398693638 |
| Android revision 4cdf32f | Native APK build and artifact upload succeeded, run 34395725064 |
| iOS revision 4cdf32f | Simulator app compile succeeded, run 34395725150 |
| Address/mobile revision ae46c74 | Database, Expo export, Android APK (34400191895), and iOS simulator (34400191843) all passed |
| Empty database replay | Recovered schema and all current migrations pass in disposable PostgreSQL 17/PostGIS; run 34400862608 |
| Database tests | 34 transactional regression checks, ten sixteen-client concurrency groups, ten coupon lifecycle/pricing groups, eight address groups and four scheduled-worker checks passed |
| JavaScript tests | 78 passed locally, zero failed |
| Supabase Edge | jana-api v13, jana-critical v5, jana-ops-extra v10 deployed ACTIVE |
| Production invariants | Negative stock, excess reservation, slot overbooking, duplicate quote orders and cash invariant counts all zero |
| Security grants | Zero anon/authenticated EXECUTE grants on new coupon writes/triggers |
| Coupon release | Database/API/web/mobile implementation present; server flag disabled without dedicated JANA PostHog configuration |

Failures were corrected and rerun: Docker health-command quoting; a health predicate incorrectly flagging refunded settlements; ambiguous SQL in quote-expiry resource release. Earlier failed/cancelled runs remain part of the audit history.

The recovered original migration files retain their exact contents. The recent repair filenames were aligned with Supabase's actual applied timestamps after deployment; SQL contents were not changed.

Remaining launch blockers include real commercial catalog/receipts/coverage and business policies, dedicated analytics configuration, PostGIS owner-grant findings, comprehensive substitutions/refunds/finance journeys, warehouse counts/cost completeness, provider adapters, backup data restore and browser/device acceptance. The master Definition of Done is not yet met.

Database scheduler `jana-quote-expiry` is installed and active every minute. Production execution succeeded on 9 September at 20:28 UTC and again on 10 September at 02:11 UTC. Render commit `42b46ce59b1ac5c6bd5dcee9175452bab8598008` is live (deployment `dep-dags8om7bikc73bram5g`).

Inventory cost migration `20260910021130` is applied. Feature commit `ffb3411` passed database run **34402318961**, including ten cost-ledger groups and fifteen Edge RPC schema contracts, and verification run **34402318960**. The append-only ledger records physical movements and proportional consumed purchase cost, preserving unknown cost and marking found-stock estimates. Seven-day reports suppress profit/margin when source cost is incomplete. All eight existing preview lots have recorded source costs; there are no delivered production orders or historical consumption entries to backfill. Application RLS now covers 34 tables; new ledger direct-client grants are zero. Production stock, reservation, capacity, duplicate-order and cash invariant checks remain zero. Reporting UI is live at `9257a412` (Render `dep-dah16j95efls73fi4cig`); live-smoke run **34428824564** and database run **34428824486** succeeded.

Assembled operations-page tests caught an older dashboard override that would replace the new report and coerce unknown margin/profit to zero. The duplicate override was removed; unknown, zero and negative financial values now pass two rendered-page tests. Total local JavaScript tests: 78 passed. The additional first negative-margin assertion was corrected to account for the Arabic locale direction mark.

Product model migration `20260910022807` is applied after database run **34429291865** passed thirteen product groups, seventeen RPC schema contracts and the earlier transaction suites. Canonical families and product versions now contain multiple sellable sizes; stable sellable lineages preserve favorites/lists compatibility. Draft creation and confirmed activation are separate. New quotes preserve canonical family/version/size identifiers. Eight existing offerings were mapped without changing their rows; before/after offering and original-order-snapshot hashes are identical. RLS covers 37 application tables. Product administration UI release is pending verification. Manual authenticated admin/browser acceptance remains unverified.
