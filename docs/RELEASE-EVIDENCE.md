# Release evidence — 9 September 2026

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
| JavaScript tests | 74 passed locally, zero failed |
| Supabase Edge | jana-api v12, jana-critical v5, jana-ops-extra v9 deployed ACTIVE |
| Production invariants | Negative stock, excess reservation, slot overbooking, duplicate quote orders and cash invariant counts all zero |
| Security grants | Zero anon/authenticated EXECUTE grants on new coupon writes/triggers |
| Coupon release | Database/API/web/mobile implementation present; server flag disabled without dedicated JANA PostHog configuration |

Failures were corrected and rerun: Docker health-command quoting; a health predicate incorrectly flagging refunded settlements; ambiguous SQL in quote-expiry resource release. Earlier failed/cancelled runs remain part of the audit history.

The recovered original migration files retain their exact contents. The recent repair filenames were aligned with Supabase's actual applied timestamps after deployment; SQL contents were not changed.

Remaining launch blockers include real commercial catalog/receipts/coverage and business policies, dedicated analytics configuration, PostGIS owner-grant findings, complete product-family administration, comprehensive substitutions/refunds/finance journeys, warehouse counts/cost completeness, provider adapters, backup data restore and browser/device acceptance. The master Definition of Done is not yet met.

Database scheduler `jana-quote-expiry` is installed and active every minute. Its function records successful executions in `worker_runs`; cron execution history must be checked after activation. Feature branch `21205d7` was fast-forwarded to `jana-live` after database, transport and native gates passed. Render deployment of that merge is being verified.
