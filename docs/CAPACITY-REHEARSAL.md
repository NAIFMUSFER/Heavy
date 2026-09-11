# Isolated capacity rehearsal

JANA has a disposable reliability gate for the Node gateway, all three canonical Edge handlers and a migrated PostgreSQL/PostGIS fixture. It sends 320 read-only catalog requests with 32 concurrent workers, records throughput and latency, then holds admitted Edge requests briefly to prove the gateway's 100-request admission boundary returns structured `503 BUSY` responses and recovers afterward.

The gate fails if any measured catalog response is not successful, catalog p95 exceeds 3 seconds, observed throughput is below 15 requests per second, overload is not shed, an unexpected burst status appears, or the post-burst catalog read does not recover. The aggregate JSON result is retained as a short-lived CI artifact. It contains no account token, catalog record or request payload.

The database guard requires the literal disposable loopback target before any fixture starts. The exercise uses no production credentials, production records or write traffic. Artificial delay is applied only inside the local bridge for the admission-boundary check.

This regression gate proves bounded behavior on one GitHub-hosted runner. It is not a production performance SLA, managed-Supabase network benchmark, real regional traffic model or operating acceptance. Before commercial claims, run an owner-approved staging test with expected product/search mix, customer geography, device networks, observability and agreed error/latency/capacity targets.

## Verified review result

Candidate `530c045e1d3dd3e1865c6973c8edfee8a77cb2d2` passed [capacity run 34568077986](https://github.com/NAIFMUSFER/Heavy/actions/runs/34568077986) at 06:00 UTC on 11 September 2026. The isolated runner completed 320 reads at concurrency 32 with 549.1 requests/second, p50 41.1 ms, p95 169.7 ms and p99 260.9 ms. A separate 125-request held burst admitted 100, shed 25 with `503 BUSY`, and then recovered. These numbers describe only that disposable runner and must not be presented as production capacity.
