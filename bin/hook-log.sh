#!/usr/bin/env bash
# Claude Code hook (PostToolUse, Stop, Notification): append the event to run_events.
# Only logs — never blocks, never fails the session. No-op outside a scheduled run.
input="$(cat)"
[[ -n "${SA_RUN_ID:-}" ]] || exit 0
if [[ -z "${PGUSER:-}" && -f "$HOME/.config/social-agent/agent.env" ]]; then
  set -a; . "$HOME/.config/social-agent/agent.env"; set +a
fi
payload="$(jq -c '{tool_input: (.tool_input // null), response_preview: ((.tool_response // "") | tostring | .[0:500])}
                  | .tool_input |= (if . == null then null else (tostring | .[0:2000]) end)' <<<"$input" 2>/dev/null || echo '{}')"
event="$(jq -r '.hook_event_name // "unknown"' <<<"$input" 2>/dev/null)"
tool="$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null)"
psql -X -q -v ON_ERROR_STOP=1 -v r="$SA_RUN_ID" -v e="$event" -v t="$tool" -v p="$payload" \
  <<<"INSERT INTO run_events (run_id, event, tool, payload) VALUES (:'r', :'e', nullif(:'t', ''), :'p'::jsonb);" \
  >/dev/null 2>&1 || true
exit 0
