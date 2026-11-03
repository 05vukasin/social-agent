#!/usr/bin/env bash
# Dispatcher — cron calls this every minute as `agent`.
# If no run is in progress, picks the single most overdue active case (respecting its
# active window) and runs it. One run at a time; everything else waits its turn.

set -Eeuo pipefail
# shellcheck disable=SC1091
[[ -f "$HOME/.config/social-agent/shell.sh" ]] && . "$HOME/.config/social-agent/shell.sh"
: "${SA_DATA:?}" "${PGUSER:?}"

[[ -f "$SA_DATA/dispatcher.paused" ]] && exit 0   # touch this file to pause all scheduling

exec 9>"$SA_DATA/run.lock"
flock -n 9 || exit 0                             # a run is in progress

next="$(psql -X -q -tA -v ON_ERROR_STOP=1 <<'SQL'
SELECT c.id FROM cases c
WHERE c.status = 'active'
  AND c.next_run_at <= now()
  AND cardinality(case_runnable_platforms(c.id)) > 0
  AND (c.active_from IS NULL OR c.active_to IS NULL
       OR CASE WHEN c.active_from <= c.active_to
               THEN localtime BETWEEN c.active_from AND c.active_to
               ELSE localtime >= c.active_from OR localtime <= c.active_to END)
ORDER BY c.next_run_at, c.priority
LIMIT 1;
SQL
)"
[[ -n "$next" ]] || exit 0

SA_LOCK_HELD=1 exec "$SA_REPO/bin/run-case.sh" "$next" --trigger cron
