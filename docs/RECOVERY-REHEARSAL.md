# Isolated fixture recovery rehearsal

## Gap and scope

Before this change, CI replayed migrations into an empty database but did not prove that a populated backup could be restored. The audit matrix and OPERATIONS-RUNBOOK.md explicitly left data restoration unverified.

The new `JANA Isolated Recovery Rehearsal` workflow restores **disposable fixtures only** into a separate PostgreSQL container. It does not download, copy, overwrite or test production data. This is a recovery regression gate, **not** a completed production backup plan, production RPO/RTO measurement or commercial-readiness approval.

## What is checked

1. Twelve pure unit tests check fixed loopback source guards, alternative libpq routing refusal, and comparison failures on missing/extra objects, changed content, privileges or sequence state.
2. Replay the reviewed schema into a new disposable database and create a real fixture order through quote, confirmation, picking, dispatch, delivery, COD collection, partial settlement and refund RPCs. Session expiry is extended only for these fixtures to allow the rehearsal.
3. Pause the disposable source scheduler without deleting or rewriting job definitions.
4. Take a complete custom-format `pg_dump` and restore it with `pg_restore --single-transaction --exit-on-error` into a fresh same-image container.
5. Compare every public table's row count and order-independent SHA-256 fingerprint, including frozen order snapshots, sessions, stock/lot data, cost and cash ledgers, refunds and persistent retry records. Empty tables remain in the comparison.
6. Compare application RLS, policies, object ownership, columns/defaults, constraints, indexes, triggers, JANA function definitions/effective grants, schema/default grants, fixture-role preconditions, public sequence state, extension versions and cron job definitions.
7. Check business invariants, read the same order using the restored custom session, replay the original confirmation without another order/reservation/cash entry, and create a new quote after recovery.

The destination has Docker network mode `none`, no published ports and scheduled execution disabled from startup. External providers are not invoked. Cluster-level fixture roles are explicitly preprovisioned because a database dump does not include global roles/passwords. Cron runtime logs and their sequence counters are not claimed as recovery evidence; job definitions and application sequence state are.

### Constraint representation\n\nThe first restore detected 16 CHECK constraints whose equivalent varchar-literal-array casts are serialized differently after PostgreSQL reparses the dump. Comparison now normalizes only that exact literal-only cast form; values, flags, names, other types, functions and expressions remain strict. Regression cases include all 16 observed pairs, changed values, escaped literals and nonmatching casts. The raw difference diagnostics remain available for a real mismatch. No production constraint was changed.\n\n## Evidence and execution

Use the workflow on `jana-integrity` or `jana-live`. It uses existing reviewed PostgreSQL 17/PostGIS/pg_cron test infrastructure. No production URL, service key, customer credential or billable recovery project is needed.

The only uploaded artifact is `evidence/local/recovery/rehearsal.json`: source commit, check names, per-table counts/hashes, metadata hashes, archive checksum/size and measured fixture dump/restore/rehearsal durations. The backup archive is temporary and deleted; row contents and fixture tokens/password hashes are not uploaded. Containers and their anonymous volumes are removed on exit and by the workflow cleanup step.

A script existing or an artifact uploading is not a pass. Inspect the complete workflow conclusion for the exact commit. The initial candidate remains pending until a successful run is recorded in RELEASE-EVIDENCE.md.

## Still required before commercial recovery readiness

- Owner-approved recovery objectives and actual backup retention/availability.
- Authorized retrieval and restoration of a real backup into a separate JANA recovery project.
- Production-scale timing, discrepancies review and authorized operational/device acceptance.
- Separate treatment of Supabase Storage objects, platform-managed schemas/roles, secrets, domains and provider configuration.
- Verified traffic cutover and worker/provider reactivation procedures. Keep outbound delivery disabled until approved.

References: [PostgreSQL 17 pg_dump](https://www.postgresql.org/docs/17/app-pgdump.html), [pg_restore](https://www.postgresql.org/docs/17/app-pgrestore.html), and [pg_cron settings](https://github.com/citusdata/pg_cron#extension-settings).
