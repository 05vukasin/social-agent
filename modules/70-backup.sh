#!/usr/bin/env bash
# Nightly backup cron (03:30 server time) → bin/backup.sh, log in /var/log/social-agent/backup.log

DESCRIPTION="noćni backup (Postgres + folderi slučajeva → S3) u 03:30"

CRON_FILE=/etc/cron.d/social-agent-backup

cron_line() { echo "30 3 * * * root $SA_REPO/bin/backup.sh >> /var/log/social-agent/backup.log 2>&1"; }

check() {
  [[ -f "$CRON_FILE" ]] && grep -qF "$(cron_line)" "$CRON_FILE" || return 1
  [[ -f /etc/logrotate.d/social-agent ]] || return 1
  command -v zstd &>/dev/null || return 1
}

apply() {
  apt_install zstd
  chmod +x "$SA_REPO"/bin/*.sh
  install -d -m 755 /var/log/social-agent
  {
    echo "# social-agent nightly backup — managed by modules/70-backup.sh"
    echo "SHELL=/bin/bash"
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    cron_line
  } > "$CRON_FILE"
  chmod 644 "$CRON_FILE"

  cat > /etc/logrotate.d/social-agent <<'EOF'
/var/log/social-agent/*.log {
  weekly
  rotate 8
  compress
  missingok
  notifempty
}
EOF
  log "probni backup…"
  "$SA_REPO/bin/backup.sh"
}
