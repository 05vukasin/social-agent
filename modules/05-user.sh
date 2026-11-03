#!/usr/bin/env bash
# The `agent` user: owns the desktop, Chrome profile, Claude Code and case folders.
# SSH hardening: key-only login.

DESCRIPTION="korisnik agent, SSH ključevi, SSH samo preko ključa"

SSHD_DROPIN=/etc/ssh/sshd_config.d/10-social-agent.conf

check() {
  user_exists "$AGENT_USER" || return 1
  id -nG "$AGENT_USER" | grep -qw sudo || return 1
  [[ -s "/home/$AGENT_USER/.ssh/authorized_keys" ]] || return 1
  [[ -f "$SSHD_DROPIN" ]] || return 1
  [[ -d "$SA_DATA/cases" ]] || return 1
}

apply() {
  if ! user_exists "$AGENT_USER"; then
    useradd -m -s /bin/bash -G sudo "$AGENT_USER"
  fi
  usermod -aG sudo "$AGENT_USER"
  echo "$AGENT_USER:$AGENT_PASSWORD" | chpasswd

  # Authorized keys = whatever root has (Hetzner puts your key there) + optional GitHub keys.
  local home="/home/$AGENT_USER" keys
  install -d -m 700 -o "$AGENT_USER" -g "$AGENT_USER" "$home/.ssh"
  keys="$(cat /root/.ssh/authorized_keys 2>/dev/null || true)"
  if [[ -n "${GITHUB_KEYS_USER:-}" ]]; then
    keys+=$'\n'"$(curl -fsSL "https://github.com/${GITHUB_KEYS_USER}.keys" || true)"
  fi
  if [[ -f "$home/.ssh/authorized_keys" ]]; then keys+=$'\n'"$(cat "$home/.ssh/authorized_keys")"; fi
  printf '%s\n' "$keys" | sed '/^\s*$/d' | sort -u > "$home/.ssh/authorized_keys"
  chown "$AGENT_USER:$AGENT_USER" "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
  [[ -s "$home/.ssh/authorized_keys" ]] || die "nema nijednog SSH ključa — dodaj ga u /root/.ssh/authorized_keys ili postavi GITHUB_KEYS_USER"

  # Key-only SSH. Root keeps key login so you can't lock yourself out mid-setup.
  cat > "$SSHD_DROPIN" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
AllowTcpForwarding yes
EOF
  sshd -t
  systemctl reload ssh

  # Data root: case folders (Claude's long-term memory), runs, backups staging.
  install -d -m 755 "$SA_DATA"
  install -d -m 750 -o "$AGENT_USER" -g "$AGENT_USER" "$SA_DATA/cases" "$SA_DATA/shared" "$SA_DATA/shared/platforms"
}
