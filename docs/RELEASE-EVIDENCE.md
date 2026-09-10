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
| JavaScript tests | 104 passed locally, zero failed |
| Supabase Edge | jana-api v16, jana-critical v5, jana-ops-extra v12 deployed ACTIVE |
| Production invariants | Negative stock, excess reservation, slot overbooking, duplicate quote orders and cash invariant counts all zero |
| Security grants | Zero anon/authenticated EXECUTE grants on new coupon writes/triggers |
| Coupon release | Database/API/web/mobile implementation present; server flag disabled without dedicated JANA PostHog configuration |

Failures were corrected and rerun: Docker health-command quoting; a health predicate incorrectly flagging refunded settlements; ambiguous SQL in quote-expiry resource release. Earlier failed/cancelled runs remain part of the audit history.

The recovered original migration files retain their exact contents. The recent repair filenames were aligned with Supabase's actual applied timestamps after deployment; SQL contents were not changed.

Remaining launch blockers include real commercial catalog/receipts/coverage and business policies, dedicated analytics configuration, PostGIS owner-grant findings, comprehensive substitutions/refunds/finance journeys, warehouse counts/cost completeness, provider adapters, backup data restore and browser/device acceptance. The master Definition of Done is not yet met.

Database scheduler `jana-quote-expiry` is installed and active every minute. Production execution succeeded on 9 September at 20:28 UTC and again on 10 September at 02:11 UTC. Render commit `42b46ce59b1ac5c6bd5dcee9175452bab8598008` is live (deployment `dep-dags8om7bikc73bram5g`).

Inventory cost migration `20260910021130` is applied. Feature commit `ffb3411` passed database run **34402318961**, including ten cost-ledger groups and fifteen Edge RPC schema contracts, and verification run **34402318960**. The append-only ledger records physical movements and proportional consumed purchase cost, preserving unknown cost and marking found-stock estimates. Seven-day reports suppress profit/margin when source cost is incomplete. All eight existing preview lots have recorded source costs; there are no delivered production orders or historical consumption entries to backfill. Application RLS now covers 34 tables; new ledger direct-client grants are zero. Production stock, reservation, capacity, duplicate-order and cash invariant checks remain zero. Reporting UI is live at `9257a412` (Render `dep-dah16j95efls73fi4cig`); live-smoke run **34428824564** and database run **34428824486** succeeded.

Assembled operations-page tests caught an older dashboard override that would replace the new report and coerce unknown margin/profit to zero. The duplicate override was removed; unknown, zero and negative financial values now pass two rendered-page tests. Total local JavaScript tests: 91 passed. The additional first negative-margin assertion was corrected to account for the Arabic locale direction mark.

Product model migration `20260910022807` is applied after database run **34429291865** passed thirteen product groups, seventeen RPC schema contracts and the earlier transaction suites. Canonical families and product versions now contain multiple sellable sizes; stable sellable lineages preserve favorites/lists compatibility. Draft creation and confirmed activation are separate. New quotes preserve canonical family/version/size identifiers. Eight existing offerings were mapped without changing their rows; before/after offering and original-order-snapshot hashes are identical. RLS covers 37 application tables. Product administration is live at `95ea6efc` (Render `dep-dah1fhh42hec73ec2qd0`); live smoke **34429865092** and database **34429865043** passed. Manual authenticated admin/browser acceptance remains unverified.

Support migration `20260910024105` applied after database run **34430171074** passed fifteen support lifecycle groups. Customer and staff replies now use the same normalized message contract; waiting-for-customer state, validated assignment, priority, close/reopen, concurrent replies and persisted idempotency are tested. Conversation edits/deletion are rejected, state changes audited, and notifications are in-app only. There were no existing production tickets to rewrite. New support RPC client grants are zero; prior PostGIS owner findings remain unchanged. Support UI is live at `308304c8` (Render `dep-dah1o05bedkc738nooj0`); smoke **34430997857** passed. Support Android **34430509624** and iOS simulator **34430509588** both passed.

Cash/refund migration `20260910030745` applied after **34431933621** passed all seventeen financial groups and earlier suites. Ledger reconciliation, payment-source separation, partial settlements, duplicate references, refund requests and completion/rejection are enforced. Original order snapshots are unchanged, cash-ledger mismatch count is zero, and there are no direct client grants on new financial RPCs. RLS covers 38 app tables; PostGIS owner findings remain unresolved. Financial UI release is pending. The service-worker cache-first defect was repaired with network refresh and offline fallback; four tests cover fresh assets, offline behavior, failed responses and cache quota failures. Gateway analytics now requires dedicated JANA project configuration; generic keys cannot enable capture.


Substitution migration `20260910033534` is applied. Database **34433806064** passed sixteen substitution groups, twenty-nine Edge/PostgreSQL signature contracts, all earlier transaction suites and the scheduled-worker test. Initial run **34433511081** failed only because a test parsed PostgreSQL boolean text as JSON; corrected JSON serialization passed the assertion. The original production order row fingerprint `d6077d5d61b0f28fd6fd2388cd4d292f` is identical before/after application. Client EXECUTE grants on JANA RPCs remain zero, reallocation helper execution by service_role is false, and new issue-table RLS is enabled. API v16 deployed. Existing PostGIS owner findings persist. Web/mobile release pending exact public-commit verification.

Financial release `0176a0b4` compiled Android **34432911178**, iOS simulator **34432911168** and Expo **34432911173** successfully; database **34432911242** passed. Render deployment `dep-dah23obl550s73d8i5bg` reported live at 03:20:46 UTC. Smoke **34432911313** attempt 1 failed on a 502 during rollout; attempt 2 failed because public `/version` still returned `308304c8` throughout the readiness window. Independent public requests confirmed old commit plus healthy dependencies at 03:34 UTC. This release is NOT VERIFIED on the public route. The mismatch is retained as evidence and must be resolved by a subsequent verified deployment.
