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

A script existing or an artifact uploading is not a pass. Inspect the complete workflow conclusion for the exact commit. Source `278d1326673b87813696304989d808049b9d840c` passed [recovery run 34548982939](https://github.com/NAIFMUSFER/Heavy/actions/runs/34548982939) on 11 September 2026 at 01:02:46 UTC: twelve guard/normalization tests and eleven integration groups; 52 public tables compared, 24 nonempty. The temporary fixture archive was 629,321 bytes; dump 0.264 seconds, restore 0.552 seconds and the measured recovery cycle 12.670 seconds (excluding fixture/bootstrap setup). These are fixture-only timings, not production objectives. There are currently no public sequences, so the successful run compared two empty public-sequence sets; populated sequence recovery is not claimed.

## Still required before commercial recovery readiness

- Owner-approved recovery objectives and actual backup retention/availability.
- Authorized retrieval and restoration of a real backup into a separate JANA recovery project.
- Production-scale timing, discrepancies review and authorized operational/device acceptance.
- Separate treatment of Supabase Storage objects, platform-managed schemas/roles, secrets, domains and provider configuration.
- Verified traffic cutover and worker/provider reactivation procedures. Keep outbound delivery disabled until approved.

References: [PostgreSQL 17 pg_dump](https://www.postgresql.org/docs/17/app-pgdump.html), [pg_restore](https://www.postgresql.org/docs/17/app-pgrestore.html), and [pg_cron settings](https://github.com/citusdata/pg_cron#extension-settings).


## Staff paging schema regression — 11 September 2026

Run [34552136730](https://github.com/NAIFMUSFER/Heavy/actions/runs/34552136730) on `40e0780470e9f096ebf2d8d7b53b959b273b4f75` includes the new staff RPC and three paging indexes. All 52 public table fingerprints and 11 integration groups passed. The pure guard suite now has 13 tests. The existing exact literal-array cast normalization also applies to partial-index definitions; recorded schema diagnostics identify the equivalent source/restored representations, and changed columns/order/predicate literals still fail. Fixture archive 634317 bytes, SHA-256 `c3084af183b3ee28974e4b10b5413bd39230575ae020b1ec2674daf14a9a6d45`; dump 0.265s / restore 0.668s / fixture cycle 14.792s. These are still fixture timings, not production RPO/RTO, backup retrieval or capacity evidence.
