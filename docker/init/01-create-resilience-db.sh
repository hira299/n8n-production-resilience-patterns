#!/bin/sh
# Runs once, on first start of an empty Postgres volume.
# Creates the "resilience" database next to n8n's own database and loads the schema.
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -c "CREATE DATABASE ${RESILIENCE_DB:-resilience};"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${RESILIENCE_DB:-resilience}" \
  -f /schema/schema.sql
