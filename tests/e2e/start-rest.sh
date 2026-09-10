#!/usr/bin/env bash
set -euo pipefail
if [[ "${JANA_TEST_DATABASE:-}" != disposable || "${PGHOST:-}" != 127.0.0.1 || "${PGDATABASE:-}" != jana_test ]]; then
  echo 'Browser database must be disposable localhost jana_test' >&2
  exit 1
fi
docker run --detach --name jana-test-rest --network host \
  --env PGRST_DB_URI=postgres://authenticator:disposable-rest-only@127.0.0.1:5432/jana_test \
  --env PGRST_DB_SCHEMAS=public \
  --env PGRST_DB_ANON_ROLE=anon \
  --env PGRST_DB_EXTRA_SEARCH_PATH=extensions,public \
  --env PGRST_JWT_SECRET=jana-disposable-browser-test-secret-32-characters-only \
  --env PGRST_SERVER_HOST=127.0.0.1 --env PGRST_SERVER_PORT=3001 \
  postgrest/postgrest:v12.2.3
for attempt in {1..30}; do
  if curl --silent --fail http://127.0.0.1:3001/ >/dev/null; then exit 0; fi
  sleep 1
done
docker logs jana-test-rest
echo 'Disposable PostgREST did not become ready' >&2
exit 1
