# JANA audit — 9 September 2026

The current source was verified byte-for-byte against GitHub `NAIFMUSFER/Heavy`, branch `jana-live`, commit `2291c2d4c0021ab828159a1a6685e5e4d98f3d10`. This branch is JANA's isolated source context. No unrelated branch, database or service is used.

| Component | Current status | Evidence | Gaps | Action required |
|---|---|---|---|---|
| Isolation | Confirmed for source, DB and gateway | Heavy/jana-live; Supabase jjdsajiwoqanefmnikls; Render srv-dagnferl550s73cbivhg | Dedicated analytics project not verified | Inspect JANA-only analytics configuration |
| Production state | Preview data; not commercially ready | API config demo=true; catalog/lot annotations mark preview stock | Real supplier receipts, prices, delivery boundaries and company policies absent | Owner must supply approved commercial inputs; preserve preview designation |
| Gateway | Security repairs tested locally | 16 HTTP tests; source allowlist; fixed upstream; 64 KiB request cap; timeouts; CSP; separate cookies | 42b46ce live; earlier address/coupon smoke passed | Verify later feature commits before release |
| Database | 60 migrations applied | 34-check PostgreSQL regression gate passed; no fixture users retained | Schema replay and sixteen-client races passed; production-data backup restore outstanding | Verify isolated data restore |
| Edge | 52 local transport tests pass | CSRF, JSON/body limits, password errors, quote idempotency, Origin enforcement | API v13, critical v5, operations v10 active | Keep function grants restricted |
| Authentication | Proven database defects fixed | NULL password and failed-attempt regression tests | Browser customer journey still unverified | Exercise same-origin cookie journey |
| Product versions | Canonical family/version/offering separation applied | Thirteen product groups and concurrent creation/activation passed; existing rows and order originals unchanged | New draft/activation admin UI awaiting release; manual acceptance unverified | Verify administration release and browser journey |
| Inventory | Receipt/inspection/reservation/consumption RPCs exist | Acceptance once, rejected lot exclusion, bounds and cancellation regression checks | Inventory role entry and available-quantity labels deployed; cost ledger and unknown-cost reporting passed ten database groups; cycle count incomplete | Complete cycle counts and review consistent inventory locking |
| Picker and courier | Assignment/OTP/weight/consumption defects repaired | PostgreSQL regression checks | Full end-to-end substitutions and all failed delivery paths not verified | Role-scoped journey and concurrency tests |
| COD and refunds | Delivery and cash separate; settlement reference required | Database regression gate | Critical financial RPC idempotency passes; partial settlement and refund cash source need review | Complete ledger and retry semantics |
| Customer web | Existing RTL store/PWA | Verified JS bundles, addresses, checkout, orders, favorites, lists | End-to-end behavior, new address/coupon UI native builds passed; Render address/coupon merge live; cost reporting UI live | Test browser and complete missing workflows |
| Mobile | Expo source retained; secure retry/session repair tested | 7 networking tests; SecureStore tokens; AsyncStorage cart | Coupon version 1b5377b passed Android/iOS builds; address version ae46c74 also passed both native builds; complete offline UI and remaining account screens | Run native CI; manual device journey |
| Android baseline | Debug native build succeeded | Actions run 34386919435 at df78003 | Android revision 4cdf32f succeeded in run 34395725064; Play signing absent | Native CI and owner Play credentials for distribution |
| iOS baseline | Simulator compile succeeded | Actions run 34389041580 at 2291c2d | iOS revision 4cdf32f succeeded in run 34395725150; distribution signing absent | Native CI and owner Apple credentials for distribution |
| CI | Prior mobile and smoke gates verified | GitHub runs inspected; latest iOS predecessor failed but corrected run passed | New smoke identified an overbroad cookie assertion; corrected to reject JANA auth cookies specifically | New smoke requires exact /version SHA; do not call queued deployment live |
| Support | Ticket RPCs and operations UI exist | Source audit | All role/customer paths not tested; refund admin route incomplete | Add scoped E2E/regressions |
| Coupons/VAT | Coupon transaction implemented, release gated | Fixed/percentage, cancellation/expiry/confirmation and weight tests pass | VAT remains unconfigured; dedicated PostHog flag unavailable | Configure JANA analytics at 0% and implement tax settings with owner policy |
| Analytics | Gateway event capture exists | Privacy-minimized event payload, sanitized route tests | PostHog project isolation/events/error tracking/flags unverified | Inspect project; leave rollout unchanged |
| Database security | JANA application tables/RPCs restricted | 37 RLS app tables; zero client execute on JANA RPCs | PostGIS owner grants still visible; prior REVOKE did not remove them | Supported Supabase administrator fix, not RLS on extension objects |
| Adapters and recovery | Work outstanding | Current repository has no complete provider/backup runbooks | Email/SMS/payment/push interfaces and verified restore missing | Implement disabled guards and document recovery |

Tests run locally here use stub upstream responses solely in tests, never in production flows. Database tests ran previously on the real JANA PostgreSQL with rollback-only fixtures. Multi-client PostgreSQL concurrency and schema replay are now verified in Actions; browser E2E, device testing and complete commercial operation remain unverified.

Current local suite: 78 passed, zero failed. The initial critical transport extension exposed two error-code mapping failures (409 versus 422); these were fixed and the suite rerun. The first live-smoke run 34395724977 failed at an assertion counting all cookies on failed login. The corrected check targets JANA session/CSRF cookies; upstream infrastructure cookies are also excluded by the gateway. The corrected live-smoke suite subsequently passed in runs 34397238501 and 34398693638.

Browser observation of existing live storefront: catalog loaded, search filtered mango, add-to-cart and cart review worked, checkout requested login. No customer account or commercial order was created through the browser.

Structured address migration 20260909202016 is applied. Eight database groups passed, including strict coordinates, ownership, geometric coverage, concurrent defaults and immutable order addresses. Expiration scheduling passed an actual pg_cron execution test in CI and is installed active every minute in JANA. Live worker execution succeeded at 02:11 UTC on 10 September.

10 September checkpoint: cost migration `20260910021130` applied after successful disposable-database CI (`34402318961`). Cost ledger is append-only with no direct client grants; profit is unknown when consumed purchase cost is missing. Reporting UI is live; smoke and database gates passed.
