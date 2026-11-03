#!/usr/bin/env bash
# Postgres 17 (+pgvector) in Docker on 127.0.0.1:5432.
# Two roles: POSTGRES_USER (owner, migrations) and PG_AGENT_USER (data read/write, no DDL).

DESCRIPTION="Postgres 17 u Docker-u (127.0.0.1:5432) + rola za agenta"

pg() { compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"; }

check() {
  compose ps --status running --services 2>/dev/null | grep -qx postgres || return 1
  compose exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" &>/dev/null || return 1
  listens_on_loopback_only 5432 || return 1
  PGPASSWORD="$PG_AGENT_PASSWORD" psql -h 127.0.0.1 -U "$PG_AGENT_USER" -d "$POSTGRES_DB" -tAc 'select 1' &>/dev/null || return 1
}

apply() {
  install -d -m 700 "$SA_DATA/postgres"
  compose pull postgres
  compose up -d postgres
  wait_for "postgres healthy" 60 compose exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"

  # Agent role: can read/write data, cannot create/drop/alter schema objects.
  pg -v agent="$PG_AGENT_USER" -v pass="$PG_AGENT_PASSWORD" -v db="$POSTGRES_DB" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'agent')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'agent') \gexec
ALTER ROLE :"agent" WITH LOGIN PASSWORD :'pass' NOSUPERUSER NOCREATEDB NOCREATEROLE;
GRANT CONNECT ON DATABASE :"db" TO :"agent";
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO :"agent";
SQL
}
