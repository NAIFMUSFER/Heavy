# Disposable PostgreSQL 17 image; no production data or credentials are copied here.
FROM postgres:17-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-17-postgis-3 postgresql-17-postgis-3-scripts postgresql-17-cron && rm -rf /var/lib/apt/lists/*
