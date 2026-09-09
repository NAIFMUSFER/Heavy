# JANA audit — 9 September 2026

The current source was verified byte-for-byte against GitHub `NAIFMUSFER/Heavy`, branch `jana-live`, commit `2291c2d4c0021ab828159a1a6685e5e4d98f3d10`. This branch is JANA's isolated source context. No unrelated branch, database or service is used.

| Component | Current status | Evidence | Gaps | Action required |
|---|---|---|---|---|
| Isolation | Confirmed for source, DB and gateway | Heavy/jana-live; Supabase jjdsajiwoqanefmnikls; Render srv-dagnferl550s73cbivhg | Dedicated analytics project not verified | Inspect JANA-only analytics configuration |
| Production state | Preview data; not commercially ready | API config demo=true; catalog/lot annotations mark preview stock | Real supplier receipts, prices, delivery boundaries and company policies absent | Owner must supply approved commercial inputs; preserve preview designation |
| Gateway | Security repairs tested locally | 16 HTTP tests; source allowlist; fixed upstream; 64 KiB request cap; timeouts; CSP; separate cookies | Deployment of current source pending | Verify /version equals deployed commit and run smoke |
| Database | 53 migrations applied | 34-check PostgreSQL regression gate passed; no fixture users retained | Historical restore and multi-connection concurrency unverified | Recover full reproducible history and run isolated restore/concurrency |
| Edge | 38 local transport tests pass | CSRF, JSON/body limits, password errors, quote idempotency, Origin enforcement | Origin patch v8/v3/v6 active; critical dispatcher Edge integration pending | Deploy 3 functions and verify versions |
| Authentication | Proven database defects fixed | NULL password and failed-attempt regression tests | Browser customer journey still unverified | Exercise same-origin cookie journey |
| Product versions | Existing immutable sold snapshots and component editor | offerings version trigger; admin component UI and stock validation RPC | No complete family/version/offering separation or new family creation | Add compatible migration and administration workflow |
| Inventory | Receipt/inspection/reservation/consumption RPCs exist | Acceptance once, rejected lot exclusion, bounds and cancellation regression checks | Inventory role entry and available-quantity labels repaired locally; cost completeness and cycle count not verified | Provide role entry and inspect cost/locking |
| Picker and courier | Assignment/OTP/weight/consumption defects repaired | PostgreSQL regression checks | Full end-to-end substitutions and all failed delivery paths not verified | Role-scoped journey and concurrency tests |
| COD and refunds | Delivery and cash separate; settlement reference required | Database regression gate | Critical financial RPC idempotency passes; partial settlement and refund cash source need review | Complete ledger and retry semantics |
| Customer web | Existing RTL store/PWA | Verified JS bundles, addresses, checkout, orders, favorites, lists | End-to-end behavior, address default coordinates and coupon checkout incomplete | Test browser and complete missing workflows |
| Mobile | Expo source retained; secure retry/session repair tested | 7 networking tests; SecureStore tokens; AsyncStorage cart | Native builds for this change pending; complete offline UI and remaining account screens | Run native CI; manual device journey |
| Android baseline | Debug native build succeeded | Actions run 34386919435 at df78003 | Android revision 4cdf32f succeeded in run 34395725064; Play signing absent | Native CI and owner Play credentials for distribution |
| iOS baseline | Simulator compile succeeded | Actions run 34389041580 at 2291c2d | iOS revision 4cdf32f succeeded in run 34395725150; distribution signing absent | Native CI and owner Apple credentials for distribution |
| CI | Prior mobile and smoke gates verified | GitHub runs inspected; latest iOS predecessor failed but corrected run passed | New smoke identified an overbroad cookie assertion; corrected to reject JANA auth cookies specifically | New smoke requires exact /version SHA; do not call queued deployment live |
| Support | Ticket RPCs and operations UI exist | Source audit | All role/customer paths not tested; refund admin route incomplete | Add scoped E2E/regressions |
| Coupons/VAT | Admin coupons exist, checkout ignores coupons | Quote source sets coupon_id NULL | Configurable VAT and usage reservation missing | Implement commercial term transaction without inventing tax policy |
| Analytics | Gateway event capture exists | Privacy-minimized event payload, sanitized route tests | PostHog project isolation/events/error tracking/flags unverified | Inspect project; leave rollout unchanged |
| Database security | JANA application tables/RPCs restricted | 33 RLS app tables; zero client execute on JANA RPCs | PostGIS owner grants still visible; prior REVOKE did not remove them | Supported Supabase administrator fix, not RLS on extension objects |
| Adapters and recovery | Work outstanding | Current repository has no complete provider/backup runbooks | Email/SMS/payment/push interfaces and verified restore missing | Implement disabled guards and document recovery |

Tests run locally here use stub upstream responses solely in tests, never in production flows. Database tests ran previously on the real JANA PostgreSQL with rollback-only fixtures. No real multi-client concurrency, browser E2E, native build of this revision or complete production journey is claimed by this matrix.

Current local suite: 61 passed, zero failed. The initial critical transport extension exposed two error-code mapping failures (409 versus 422); these were fixed and the suite rerun. The first live-smoke run 34395724977 failed at an assertion counting all cookies on failed login. The corrected check targets JANA session/CSRF cookies; upstream infrastructure cookies are also excluded by the gateway. New public verification remains required.

Browser observation of existing live storefront: catalog loaded, search filtered mango, add-to-cart and cart review worked, checkout requested login. No customer account or commercial order was created through the browser.
