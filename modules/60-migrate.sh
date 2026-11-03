#!/usr/bin/env bash
# Database schema: apply every pending migrations/*.sql (see bin/migrate.sh).

DESCRIPTION="SQL migracije (migrations/*.sql)"

check() { bash "$SA_REPO/bin/migrate.sh" --pending &>/dev/null; }

apply() { bash "$SA_REPO/bin/migrate.sh"; }
