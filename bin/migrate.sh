#!/usr/bin/env bash
# Apply SQL migrations from migrations/*.sql in order, each in one transaction.
# Applied versions are recorded in schema_migrations. Safe to run any number of times.
#
#   sudo migrate.sh            # apply pending
#   sudo migrate.sh --status   # list applied / pending
#   sudo migrate.sh --pending  # exit 0 if nothing pending, 1 otherwise (used by setup check)

source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
SA_MODULE=migrate
load_env

psql_admin() { compose exec -T postgres psql -v ON_ERROR_STOP=1 -X -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"; }

psql_admin -c "CREATE TABLE IF NOT EXISTS schema_migrations (
  version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now(), checksum text NOT NULL)" >/dev/null

applied="$(psql_admin -tAc 'SELECT version FROM schema_migrations ORDER BY version')"

pending=()
for f in "$SA_REPO"/migrations/*.sql; do
  v="$(basename "$f" .sql)"
  grep -qx "$v" <<<"$applied" || pending+=("$f")
done

case "${1:-}" in
  --pending) ((${#pending[@]} == 0)); exit ;;
  --status)
    while read -r v; do [[ -n "$v" ]] && ok "$v"; done <<<"$applied"
    for f in "${pending[@]}"; do warn "pending $(basename "$f" .sql)"; done
    exit 0 ;;
esac

for f in "${pending[@]}"; do
  v="$(basename "$f" .sql)"
  sum="$(sha256sum "$f" | cut -c1-64)"
  log "primenjujem $v"
  { cat "$f"; printf "\nINSERT INTO schema_migrations (version, checksum) VALUES ('%s', '%s');\n" "$v" "$sum"; } \
    | psql_admin --single-transaction
  ok "$v"
done

# Agent role gets data rights on everything that exists now and everything created later.
psql_admin -v agent="$PG_AGENT_USER" -v owner="$POSTGRES_USER" >/dev/null <<'SQL'
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"agent";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"agent";
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO :"agent";
REVOKE ALL ON schema_migrations FROM :"agent";
GRANT SELECT ON schema_migrations TO :"agent";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"agent";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO :"agent";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO :"agent";
SQL

((${#pending[@]})) || ok "nema novih migracija"
