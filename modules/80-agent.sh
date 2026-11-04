#!/usr/bin/env bash
# The agent runtime: skills, Claude settings (logging hooks), shared notes, dispatcher cron.
# On first install the dispatcher starts PAUSED ($SA_DATA/dispatcher.paused) — remove that file
# after a successful manual run:  rm /srv/social-agent/dispatcher.paused

DESCRIPTION="agent: skilovi, hookovi, dispatcher (svaki minut) + healthcheck (svakih 5 min)"

CRON_FILE=/etc/cron.d/social-agent-dispatch
HEALTH_CRON=/etc/cron.d/social-agent-health

skills() { find "$SA_REPO/claude/skills" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'; }

cron_line() { echo "* * * * * $AGENT_USER bash -lc '$SA_REPO/bin/dispatch.sh' >> $SA_DATA/logs/dispatch.log 2>&1"; }
health_line() { echo "*/5 * * * * $AGENT_USER bash -lc '$SA_REPO/bin/healthcheck.sh --quiet' >> $SA_DATA/logs/health.log 2>&1"; }

check() {
  local home="/home/$AGENT_USER" s
  for s in $(skills); do [[ -L "$home/.claude/skills/$s" ]] || return 1; done
  jq -e '.hooks.PostToolUse' "$home/.claude/settings.json" &>/dev/null || return 1
  [[ -f "$CRON_FILE" ]] && grep -qF "$(cron_line)" "$CRON_FILE" || return 1
  [[ -f "$HEALTH_CRON" ]] && grep -qF "$(health_line)" "$HEALTH_CRON" || return 1
  [[ -f "$SA_DATA/shared/platforms/web.md" ]] || return 1
  as_agent 'command -v agentctl' &>/dev/null || return 1
}

apply() {
  local home="/home/$AGENT_USER" s
  chmod +x "$SA_REPO"/bin/*
  agent_mkdir "$home/.claude/skills"
  chown "$AGENT_USER:$AGENT_USER" "$SA_DATA"   # run.lock, dispatcher.paused (non-recursive)
  install -d -m 750 -o "$AGENT_USER" -g "$AGENT_USER" "$SA_DATA/logs"

  # Skills are symlinks into the repo → `git pull` updates them.
  for s in $(skills); do
    ln -sfn "$SA_REPO/claude/skills/$s" "$home/.claude/skills/$s"
  done
  chown -h "$AGENT_USER:$AGENT_USER" "$home"/.claude/skills/*

  # Merge hooks into the agent's Claude settings (keeps theme etc.).
  local settings="$home/.claude/settings.json" tmp; tmp="$(mktemp)"
  [[ -f "$settings" ]] || echo '{}' > "$settings"
  jq --arg hook "$SA_REPO/bin/hook-log.sh" '
    .hooks.PostToolUse = [{"matcher": "*", "hooks": [{"type": "command", "command": $hook}]}]
    | .hooks.Stop = [{"hooks": [{"type": "command", "command": $hook}]}]
    | .hooks.Notification = [{"hooks": [{"type": "command", "command": $hook}]}]
  ' "$settings" > "$tmp"
  install -m 600 -o "$AGENT_USER" -g "$AGENT_USER" "$tmp" "$settings"; rm -f "$tmp"

  # Seed shared platform notes (agent-owned afterwards; never overwritten).
  local f
  for f in "$SA_REPO"/templates/shared/platforms/*.md; do
    [[ -f "$SA_DATA/shared/platforms/$(basename "$f")" ]] || \
      install -m 640 -o "$AGENT_USER" -g "$AGENT_USER" "$f" "$SA_DATA/shared/platforms/$(basename "$f")"
  done

  # Dispatcher cron. First install starts paused.
  if [[ ! -f "$CRON_FILE" ]]; then
    touch "$SA_DATA/dispatcher.paused"; chown "$AGENT_USER:$AGENT_USER" "$SA_DATA/dispatcher.paused"
    warn "dispatcher je instaliran PAUZIRAN — posle uspešnog ručnog runa: rm $SA_DATA/dispatcher.paused"
  fi
  {
    echo "# social-agent dispatcher — managed by modules/80-agent.sh"
    echo "# pause all scheduling: touch $SA_DATA/dispatcher.paused"
    cron_line
  } > "$CRON_FILE"
  chmod 644 "$CRON_FILE"

  {
    echo "# social-agent healthcheck → system_health + alerts — managed by modules/80-agent.sh"
    health_line
  } > "$HEALTH_CRON"
  chmod 644 "$HEALTH_CRON"
  as_agent "$SA_REPO/bin/healthcheck.sh" || true
}
