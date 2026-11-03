#!/usr/bin/env bash
# Run ONE case: fresh Claude session, long-term memory in the case folder.
#
#   run-case.sh <case-id|slug> [--trigger manual|cron]
#
# Runs as the `agent` user. Flow:
#   lock → runs row → case folder (git, CLAUDE.md from DB, NOTES.md) → claude -p → record result
#   → schedule next run → git commit the folder.

set -Eeuo pipefail

[[ "$(id -un)" == "${AGENT_USER:-agent}" ]] || { echo "pokreni kao agent: sudo -u agent -i run-case.sh ..." >&2; exit 1; }
# shellcheck disable=SC1091
[[ -f "$HOME/.config/social-agent/shell.sh" ]] && . "$HOME/.config/social-agent/shell.sh"
: "${SA_REPO:?}" "${SA_DATA:?}" "${PGUSER:?agent.env nije učitan}"

target="${1:?upotreba: run-case.sh <case-id|slug> [--trigger manual|cron]}"; shift
trigger=manual
while (($#)); do case "$1" in --trigger) trigger="$2"; shift 2 ;; *) shift ;; esac; done

TIMEOUT="${SA_RUN_TIMEOUT:-45m}"
LOCK="$SA_DATA/run.lock"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 "$@"; }

# One run at a time (one Chrome, one subscription). dispatch.sh already holds the lock.
if [[ -z "${SA_LOCK_HELD:-}" ]]; then
  exec 9>"$LOCK"
  flock -w 10 9 || { log "drugi run je u toku — pokušaj kasnije"; exit 3; }
fi

IFS='|' read -r CASE_ID SLUG CASE_NAME INTERVAL < <(q -v t="$target" <<'SQL'
SELECT id || '|' || slug || '|' || name || '|' || interval_minutes FROM cases
WHERE id::text = :'t' OR slug = :'t' LIMIT 1;
SQL
)
[[ -n "${CASE_ID:-}" ]] || { log "slučaj '$target' ne postoji"; exit 1; }
PLATFORMS="$(q -v c="$CASE_ID" <<<"SELECT array_to_string(case_runnable_platforms(:'c'), ',');")"

if [[ -z "$PLATFORMS" ]]; then
  log "$CASE_NAME: nijedna platforma trenutno nije dostupna (needs_human/disabled) — preskačem"
  q -v c="$CASE_ID" <<<"UPDATE cases SET next_run_at = now() + interval '30 minutes' WHERE id = :'c';"
  exit 0
fi

RUN_ID="$(q -v c="$CASE_ID" -v tr="$trigger" <<<"INSERT INTO runs (case_id, trigger) VALUES (:'c', :'tr') RETURNING id;")"
export SA_CASE_ID="$CASE_ID" SA_RUN_ID="$RUN_ID"
log "run $RUN_ID · $CASE_NAME · platforme: $PLATFORMS"

# ------------------------------------------------------------------ case folder (long-term memory)
DIR="$SA_DATA/cases/$SLUG"
TS="$(date +%Y-%m-%dT%H-%M)"
mkdir -p "$DIR/platforms" "$DIR/runs" "$DIR/scripts"
if [[ ! -d "$DIR/.git" ]]; then
  git -C "$DIR" init -q -b main
  git -C "$DIR" config user.name "social-agent"
  git -C "$DIR" config user.email "agent@localhost"
  printf 'runs/*.stderr\n*.png\n*.jpg\n' > "$DIR/.gitignore"
fi

[[ -f "$DIR/NOTES.md" ]] || cp "$SA_REPO/templates/case/NOTES.md" "$DIR/NOTES.md"
IFS=',' read -ra PLIST <<<"$PLATFORMS"
for p in "${PLIST[@]}"; do
  [[ -f "$DIR/platforms/$p.md" ]] || printf '# Strategija za %s — ovaj slučaj\n\n_(prazno — popuni posle prvog runa: šta radi, koji upiti/izvori daju rezultat, šta je šum)_\n' "$p" > "$DIR/platforms/$p.md"
  mkdir -p "$SA_DATA/shared/platforms"
  [[ -f "$SA_DATA/shared/platforms/$p.md" ]] || cp "$SA_REPO/templates/shared/platforms/$p.md" "$SA_DATA/shared/platforms/$p.md" 2>/dev/null || true
done

# CLAUDE.md is regenerated from the DB every run (single source of truth for the definition).
{
  echo "<!-- GENERISANO iz baze pri svakom runu ($TS). Ne menjaj ovde: tvoje pamćenje je NOTES.md i platforms/*.md -->"
  agentctl context
  echo
  echo "## Tvoje pamćenje (čitaj pre rada, ažuriraj na kraju)"
  echo
  echo "- \`NOTES.md\` — glavno pamćenje za ovaj slučaj"
  for p in "${PLIST[@]}"; do echo "- \`platforms/$p.md\` — strategija za $p u ovom slučaju"; done
  for p in "${PLIST[@]}"; do echo "- \`$SA_DATA/shared/platforms/$p.md\` — opšte znanje o platformi $p (važi za sve slučajeve)"; done
  echo "- \`scripts/\` — tvoji pomoćni alati za ovaj slučaj"
} > "$DIR/CLAUDE.md"

# ------------------------------------------------------------------ the Claude session
PROMPT="Zakazani run za slučaj opisan u CLAUDE.md.
RUN_ID=$RUN_ID · CASE_ID=$CASE_ID · dozvoljene platforme SADA: $PLATFORMS · vreme: $(date '+%F %H:%M %Z')
Pozovi skill \`social-collect\` i prati ga od početka do kraja (za svaku platformu i njen skill \`platform-<ime>\`).
Ne staj dok ne završiš korak 'Kraj runa' (ažuriran NOTES.md + agentctl run-summary)."

ALLOWED=(
  "WebSearch" "WebFetch" "mcp__claude-in-chrome__*"
  "Read" "Write" "Edit" "Glob" "Grep" "Skill" "TodoWrite"
  "Bash(agentctl:*)" "Bash(psql:*)" "Bash(curl:*)" "Bash(jq:*)" "Bash(date:*)"
  "Bash(ls:*)" "Bash(cat:*)" "Bash(head:*)" "Bash(grep:*)" "Bash(wc:*)" "Bash(python3:*)"
)

OUT="$DIR/runs/$TS.json"
rc=0
(
  cd "$DIR"
  DISPLAY="${DISPLAY:-:1}" timeout --kill-after=60 "$TIMEOUT" \
    claude -p --chrome \
      --permission-mode acceptEdits \
      --allowedTools "${ALLOWED[@]}" \
      --add-dir "$SA_DATA/shared" \
      --output-format json \
      ${SA_CLAUDE_MODEL:+--model "$SA_CLAUDE_MODEL"} \
      "$PROMPT"
) > "$OUT" 2> "$DIR/runs/$TS.stderr" || rc=$?

# ------------------------------------------------------------------ record result
is_error="$(jq -r '.is_error // true' "$OUT" 2>/dev/null || echo true)"
result_text="$(jq -r '.result // ""' "$OUT" 2>/dev/null || true)"
if ((rc == 124 || rc == 137)); then
  status=timeout
elif grep -qiE 'usage limit|rate.?limit|limit (reached|will reset)|resets at' <<<"$result_text$(cat "$DIR/runs/$TS.stderr")"; then
  status=rate_limited
elif [[ "$is_error" == "false" && $rc -eq 0 ]]; then
  status=success
else
  status=failed
fi

stats="$(jq -c '{session_id, num_turns, duration_ms, total_cost_usd, subtype, usage: {input: .usage.input_tokens, output: .usage.output_tokens, cache_read: .usage.cache_read_input_tokens}}' "$OUT" 2>/dev/null || echo '{}')"
session="$(jq -r '.session_id // empty' "$OUT" 2>/dev/null || true)"

q -v r="$RUN_ID" -v st="$status" -v stats="$stats" -v sess="$session" -v res="$result_text" \
  -v plat="$PLATFORMS" -v err="$(tail -c 2000 "$DIR/runs/$TS.stderr")" <<'SQL'
UPDATE runs SET status = :'st', finished_at = now(), stats = :'stats'::jsonb,
       claude_session_id = nullif(:'sess', ''),
       summary = coalesce(summary, nullif(:'res', '')),
       error = CASE WHEN :'st' <> 'success' THEN nullif(left(:'res' || E'\n' || :'err', 4000), E'\n') END,
       platforms_done = string_to_array(:'plat', ',')
WHERE id = :'r';
SQL

# Schedule next run. Rate limit → retry in an hour; 3 failures in a row → pause + alert.
q -v c="$CASE_ID" -v st="$status" -v r="$RUN_ID" <<'SQL'
UPDATE cases SET
  last_run_at = now(),
  last_run_status = :'st',
  consecutive_failures = CASE WHEN :'st' IN ('success', 'rate_limited') THEN 0 ELSE consecutive_failures + 1 END,
  next_run_at = now() + CASE WHEN :'st' = 'rate_limited' THEN interval '60 minutes'
                             ELSE make_interval(mins => interval_minutes) END
WHERE id = :'c';
INSERT INTO alerts (kind, case_id, run_id, message)
SELECT 'error', id, :'r', 'Slučaj pauziran posle 3 neuspešna runa zaredom — pogledaj runs.error'
FROM cases WHERE id = :'c' AND consecutive_failures >= 3 AND status = 'active';
UPDATE cases SET status = 'paused' WHERE id = :'c' AND consecutive_failures >= 3;
SQL

git -C "$DIR" add -A
git -C "$DIR" commit -q -m "run $TS · $status · $(q -v r="$RUN_ID" <<<"SELECT '+' || new_posts || ' postova, +' || new_comments || ' komentara' FROM runs WHERE id = :'r';")" || true

log "gotovo: $status · $(q -v r="$RUN_ID" <<<"SELECT new_posts || ' novih postova, ' || new_comments || ' komentara' FROM runs WHERE id = :'r';")"
[[ "$status" == success ]]
