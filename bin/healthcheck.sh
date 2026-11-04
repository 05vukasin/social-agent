#!/usr/bin/env bash
# Health check — cron every 5 min as `agent`. Writes system_health via report_health();
# errors open an alert (one per component), recovery auto-resolves it.
#
#   healthcheck.sh          # check everything, print a table
#   healthcheck.sh --quiet  # cron mode: print only changes and problems
#
# Components: claude_auth, chrome, desktop, postgres, s3, disk, dispatcher, runs, backup.

set -uo pipefail   # no -e: one failing check must not stop the others
# shellcheck disable=SC1091
[[ -f "$HOME/.config/social-agent/shell.sh" ]] && . "$HOME/.config/social-agent/shell.sh"
: "${SA_DATA:?}" "${PGUSER:?}"

quiet=0; [[ "${1:-}" == --quiet ]] && quiet=1
q() { psql -X -q -tA -v ON_ERROR_STOP=1 "$@"; }

report() {  # component status message [details-json]
  local out d="${4:-}"
  [[ -n "$d" ]] || d='{}'
  out="$(q -v c="$1" -v s="$2" -v m="$3" -v d="$d" \
        <<<"SELECT report_health(:'c', :'s', :'m', :'d'::jsonb);" 2>&1)" || out="DB greška: $out"
  if ((quiet == 0)) || [[ "$2" != ok ]] || [[ "$out" != *"ok → ok" ]]; then
    printf '[%s] %-12s %-5s %s   (%s)\n' "$(date '+%F %T')" "$1" "$2" "$3" "$out"
  fi
}

# ---------------------------------------------------------------- postgres (everything else depends on it)
if ! q -c 'SELECT 1' >/dev/null 2>&1; then
  echo "[$(date '+%F %T')] postgres ERROR — baza nedostupna, ostale provere se ne mogu upisati" >&2
  exit 1
fi
report postgres ok "baza odgovara"

# ---------------------------------------------------------------- Claude login (no tokens spent)
auth="$(timeout 30 claude auth status 2>&1)"
if jq -e '.loggedIn == true' <<<"$auth" >/dev/null 2>&1; then
  report claude_auth ok "ulogovan ($(jq -r '.authMethod // "?"' <<<"$auth"))"
else
  report claude_auth error "Claude NIJE ulogovan — dispatcher čeka. Reši: VNC → terminal → claude → /login" \
    "$(jq -nc --arg o "${auth:0:500}" '{output: $o}')"
fi

# ---------------------------------------------------------------- desktop (VNC :1)
if ss -ltnH 'sport = :5901' | grep -q .; then
  report desktop ok "VNC :1 radi"
else
  report desktop error "VNC desktop ne radi (sudo systemctl restart vnc-agent)"
fi

# ---------------------------------------------------------------- Chrome (CDP); restart once if down
cdp() { curl -fsS --max-time 5 http://127.0.0.1:9222/json/version 2>/dev/null; }
if v="$(cdp)"; then
  report chrome ok "$(jq -r '.Browser' <<<"$v")"
else
  DISPLAY=:1 setsid /usr/local/bin/agent-chrome >/dev/null 2>&1 < /dev/null &
  sleep 8
  if v="$(cdp)"; then
    report chrome warn "Chrome je bio ugašen — automatski ponovo pokrenut ($(jq -r '.Browser' <<<"$v"))"
  else
    report chrome error "Chrome ne radi i nije uspeo restart (proveri VNC desktop)"
  fi
fi

# ---------------------------------------------------------------- S3
if timeout 30 rclone lsf "s3:${S3_BUCKET}" --max-depth 1 >/dev/null 2>&1; then
  report s3 ok "bucket ${S3_BUCKET} dostupan"
else
  report s3 error "S3 (Garage) nedostupan"
fi

# ---------------------------------------------------------------- disk
used="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
if ((used < 85)); then report disk ok "${used}% zauzeto"
elif ((used < 95)); then report disk warn "${used}% zauzeto — počisti ili proširi disk"
else report disk error "${used}% zauzeto — disk skoro pun"; fi

# ---------------------------------------------------------------- dispatcher
if [[ -f "$SA_DATA/dispatcher.paused" ]]; then
  report dispatcher warn "PAUZIRAN (rm $SA_DATA/dispatcher.paused za uključivanje)"
else
  overdue="$(q <<<"SELECT count(*) FROM cases WHERE status = 'active' AND next_run_at < now() - interval '3 hours' AND cardinality(case_runnable_platforms(id)) > 0;")"
  if ((overdue > 0)); then
    report dispatcher warn "$overdue aktivnih slučajeva kasni više od 3h (red čekanja ili limit pretplate)"
  else
    report dispatcher ok "radi, nema zaostalih slučajeva"
  fi
fi

# ---------------------------------------------------------------- runs: stale + rate limit
# A run 'running' for >70 min has no live process (timeout is 45 min) → close it.
stale="$(q <<<"UPDATE runs SET status = 'incomplete', finished_at = now(), error = 'proces nestao (healthcheck)'
               WHERE status = 'running' AND started_at < now() - interval '70 minutes' RETURNING id;" | grep -c . || true)"
last="$(q <<<"SELECT status FROM runs WHERE status <> 'running' ORDER BY started_at DESC LIMIT 1;")"
if ((stale > 0)); then
  report runs warn "$stale run(ova) visilo bez procesa — zatvoreni kao incomplete"
elif [[ "$last" == rate_limited ]]; then
  report runs warn "poslednji run je udario u limit pretplate — dispatcher pokušava ponovo za sat"
else
  report runs ok "poslednji run: ${last:-nema}"
fi

# ---------------------------------------------------------------- backup freshness
latest="$(timeout 60 rclone lsf "s3:${S3_BUCKET}/backups/pg/" 2>/dev/null | sort | tail -1)"
if [[ -z "$latest" ]]; then
  report backup error "nema nijednog backup-a baze u S3"
else
  ts="${latest%.dump}"                                      # 2026-11-04T03-30
  ts_epoch="$(date -d "${ts:0:10} ${ts:11:2}:${ts:14:2}" +%s 2>/dev/null || echo 0)"
  age_h=$(( ($(date +%s) - ts_epoch) / 3600 ))
  if ((age_h <= 26)); then report backup ok "poslednji: $latest (pre ${age_h}h)"
  else report backup error "poslednji backup je star ${age_h}h ($latest) — proveri /var/log/social-agent/backup.log"; fi
fi
