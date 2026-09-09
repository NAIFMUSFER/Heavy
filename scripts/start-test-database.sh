#!/usr/bin/env bash
set -euo pipefail
if [[ "${JANA_TEST_DATABASE:-}" != disposable || "${PGHOST:-}" != 127.0.0.1 || "${PGDATABASE:-}" != jana_test ]]; then
  echo 'Refusing to create fixtures outside disposable loopback jana_test database' >&2
  exit 1
fi
docker build -f tests/postgres.Dockerfile -t jana-test-postgres .
docker run --detach --name jana-test-postgres --publish 127.0.0.1:5432:5432 --env POSTGRES_USER=postgres --env POSTGRES_DB=jana_test --env POSTGRES_PASSWORD=disposable-ci-only jana-test-postgres -c shared_preload_libraries=pg_cron -c cron.database_name=jana_test
for attempt in {1..30}; do
  if docker exec jana-test-postgres pg_isready -U postgres -d jana_test >/dev/null 2>&1; then
    # The image's init process uses a temporary Unix socket server. Wait for TCP.
    if pg_isready -h 127.0.0.1 -U postgres -d jana_test >/dev/null 2>&1; then exit 0; fi
  fi
  sleep 1
done
echo 'Disposable database did not become ready' >&2
exit 1
