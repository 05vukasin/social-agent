#!/usr/bin/env bash
# Base OS: packages, timezone, locale, firewall, fail2ban, unattended upgrades, swap.

DESCRIPTION="osnovni paketi, timezone, ufw (samo SSH), fail2ban, swap"

BASE_PKGS=(
  ca-certificates curl wget gnupg git jq unzip zip rsync htop tmux vim less
  openssl gettext-base sudo locales tzdata cron logrotate
  ufw fail2ban unattended-upgrades
  rclone postgresql-client
  python3 python3-venv
)

check() {
  [[ -z "$(pkgs_missing "${BASE_PKGS[@]}")" ]] || return 1
  [[ "$(timedatectl show -p Timezone --value 2>/dev/null)" == "${SA_TZ:-Europe/Belgrade}" ]] || return 1
  ufw status 2>/dev/null | grep -q "Status: active" || return 1
  systemctl is-active --quiet fail2ban || return 1
  swapon --show=NAME --noheadings | grep -q . || return 1
}

apply() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y
  apt_install "${BASE_PKGS[@]}"

  timedatectl set-timezone "${SA_TZ:-Europe/Belgrade}"
  if ! locale -a | grep -qi 'sr_RS.utf8'; then
    sed -i 's/^# *\(sr_RS.UTF-8\)/\1/; s/^# *\(sr_RS@latin UTF-8\)/\1/; s/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen
    locale-gen
  fi

  # Firewall: only SSH in. VNC, Postgres, Garage all bind to 127.0.0.1 → reach them via SSH tunnel.
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH
  ufw --force enable

  systemctl enable --now fail2ban
  dpkg-reconfigure -f noninteractive unattended-upgrades
  systemctl enable --now cron

  # 4G swapfile: Chrome with heavy feeds can spike RAM on an 8 GB box.
  if ! swapon --show=NAME --noheadings | grep -q .; then
    fallocate -l "${SA_SWAP_SIZE:-4G}" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=10 >/dev/null
    echo 'vm.swappiness=10' > /etc/sysctl.d/90-social-agent.conf
  fi
}
