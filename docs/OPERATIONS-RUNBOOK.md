# Deployment, verification and recovery

## Source and release

Use the isolated `jana-live` production branch and `jana-integrity` review branch. Preserve deployed migration history. Run Node syntax/bundle checks, executable tests and disposable PostgreSQL/PostGIS replay. Mobile changes require Expo export and native Android/iOS simulator gates. Inspect actual workflow conclusions: queued or running is not successful.

Apply reviewed forward migrations to the dedicated JANA Supabase project only after database gates pass. Check application RLS, explicit function EXECUTE privileges and invariant counts afterward. Store the exact SQL under the applied Supabase timestamp; rename a predeployment filename if needed without changing its SQL. Deploy the reviewed Edge entrypoint and all local imports, retaining custom authentication. Reconcile deployed sources with the tested commit.

Promote the tested source tree to `jana-live`. Inspect Render deploys before creating another deployment. In this session GitHub API ref updates did not reliably start Render builds, despite auto-deploy being enabled; manually triggering the JANA service was necessary. Do not create duplicate pending deploys. Render's `live` status alone is insufficient: check `/version` equals the intended commit, `/ready` confirms all Edge dependencies and the production smoke job succeeds. An earlier financial rollout briefly reported live while public traffic still served an older commit; subsequent verified deployment resolved it. Every new release still requires exact public commit and dependency verification.

The public smoke suite checks current commit, dependencies, public assets, anonymous authentication rejection and invalid login behavior. It never inserts production orders or stock. Deployment polling reads only version/readiness. The complete smoke submits its invalid login once; repeated business writes are never used as health probes.

## Local setup and test data

Install Node 24. Run `npm run check`, `npm test` and `node server.js`. The gateway has no npm runtime dependencies. Its fixed upstream defaults to the real dedicated JANA service: local browsing is not a disposable commerce environment. Do not submit test stock or orders there. Development isolation currently exists through injected test transports and disposable database fixtures; a full dedicated staging Supabase/gateway environment is still required.

For database tests, use Docker and the exact environment/sequence in `.github/workflows/jana-database.yml`. The scripts refuse targets other than a disposable loopback `jana_test` database. Start `scripts/start-test-database.sh`, replay `scripts/bootstrap-test-database.py`, then run the configured regression, RPC-contract and concurrency scripts. Always remove the disposable container afterward. Recovered historical schema lives under `tests/database-history`; preview seed credentials/data are deliberately excluded.

Expo instructions and EAS development/preview/production profiles are in `mobile/`. Native CI generates debug Android and simulator iOS artifacts. These are not signed store releases. Preserve the established `com.jana.fresh` identifier until the owner confirms distribution registration. No Apple, Google or merchant credentials are fabricated.

## Backup and restore

CI now includes a populated **fixture-only** backup/restore rehearsal in a separate network-isolated database. It verifies table contents, application permissions/constraints and functional order/retry recovery. See [RECOVERY-REHEARSAL.md](RECOVERY-REHEARSAL.md) for verified runs, limitations and artifact handling. This supplements schema replay; it does not replace the production recovery requirements below.

Before commercial launch, confirm the actual Supabase plan, available retention and recovery facilities. Record approved RPO/RTO. A schema replay test is not a production-data restore. Supabase backup coverage depends on plan; storage objects need a separate backup strategy. Follow the [official backup guide](https://supabase.com/docs/guides/platform/backups).

Restore into a new, isolated JANA recovery project. Never overwrite production to test recovery. Validate row counts, order original snapshots, cash/refund reconciliation, lot/balance reservations, slot capacity, FK constraints, application RLS, RPC privileges and worker schedules. Disable external delivery of notifications and production analytics in recovery. Verify customer/operations authentication using authorized test accounts, and measure the complete restore duration. Document discrepancies before allowing traffic. A real backup restore and measured RPO/RTO are currently NOT VERIFIED.

## Rollback and incident response

For application failure, create a new reviewed commit restoring the last known-compatible application tree and deploy it to the same JANA service. Verify commit and health through the public URL. Do not blindly roll back an application that expects an older incompatible database schema. Database repairs use a reviewed forward migration. Data restoration or financially material corrections require explicit owner review of the concrete proposed changes.

If checkout failures increase, inspect structured request IDs, status/latency, Render logs, Edge errors and PostgreSQL invariants. Avoid repeating orders or cash operations to diagnose health. Inspect `worker_runs` and `cron.job_run_details` if quote/substitution expiration stalls. Failed or rejected cash operations must not be recorded as successful externally.

Rotate secrets only inside JANA-owned configuration. Keep service-role credentials out of the browser, mobile and gateway. Validate Edge dependencies after rotation and revoke the previous credential after successful cutover. Custom session revocation is performed through JANA session records; do not assume rotating a Supabase API key invalidates opaque customer sessions. Never print secrets in logs or commit them.

## Configuration still required

Dedicated staging infrastructure; commercial catalog, accepted real receipts and approved geographic/slot settings; merchant tax status and policies; dedicated PostHog project and initial zero-percent flags; verified JANA email domain; SMS/WhatsApp/push/payment credentials; Apple/Google distribution accounts; approved backups and restore evidence. No external message sending or financial-provider charge is enabled by this runbook.

## Commercial admission

Use the administrator storefront settings described in `COMMERCIAL-STOREFRONT.md`. Default production admission is closed until actual merchant data, policies and operations are reviewed. Closing stops fresh quotes; it does not cancel existing valid quotes or interfere with existing order fulfillment. Publish approved policies before opening. Do not choose a tax declaration or complete physical-operation attestations on behalf of the owner.


## Render public-repository deployment observation — 11 September 2026

The JANA service reports `autoDeploy:yes` / `autoDeployTrigger:commit`, but its build log says it lacks repository access and clones the public Git URL. After promotion of ca1f650, no automatic deployment appeared; the reviewed release was deployed once through the existing Render connector. [Render documents](https://render.com/docs/deploys#automatic-deploys) that automatic deploys require a connected Git provider, while public-URL services deploy manually. Treat the flag alone as insufficient evidence of a working webhook.

Before each release, verify current branch heads, relevant successful CI on the release source, service branch and recent deploys. Observe whether a deployment starts. If one is pending/running, monitor it instead of issuing another. For this documented public-clone configuration, trigger a single manual deploy only after establishing that no automatic deployment exists; verify its resolved commit, public smoke and health. Connecting GitHub to Render for webhook-based deployment needs the owner's Git-provider authorization; it is not required to use the existing controlled release path. Do not bypass CI or alter unrelated services.


## Hosting suspension gate

Before promotion or deploy, inspect the current service's `suspended` and `suspenders` fields as well as its deployment history. A deployment with historical status `live` can belong to a currently suspended service. On September 11 the JANA service returned `suspended: suspended` / `suspenders: [billing]`; the owner must inspect the workspace Billing notice to identify and resolve the specific account/usage cause. No charge or upgrade is approved by this observation. Do not infer an invoice balance, repeatedly trigger deployments, resume around a billing restriction, move services to another project, or modify unrelated workspace services.

Retain successful candidate CI and record backend changes separately. While suspension persists, do not claim public health or post-deployment smoke. After resolution, recheck the latest refs/source gates and absence of a running deploy, then follow the existing controlled deployment procedure. The current checkout migration is additive and compatible with the old web gateway. Other isolated source/testing work remains available while the owner resolves hosting.
