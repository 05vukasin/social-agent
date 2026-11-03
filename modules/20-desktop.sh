#!/usr/bin/env bash
# Minimal XFCE desktop served by TigerVNC on display :1, bound to localhost only.
# Connect with: ssh -L 5901:localhost:5901 agent@SERVER  → VNC client to localhost:5901
# The VNC session IS the agent's desktop: Chrome and cron-launched Claude runs use DISPLAY=:1.

DESCRIPTION="XFCE desktop + TigerVNC (:1, samo localhost)"

DESKTOP_PKGS=(
  xfce4 xfce4-terminal xfce4-taskmanager mousepad thunar dbus-x11 at-spi2-core
  tigervnc-standalone-server tigervnc-tools
  fonts-noto-core fonts-noto-color-emoji fonts-dejavu fonts-liberation
  xclip xdotool
)
UNIT=/etc/systemd/system/vnc-agent.service

check() {
  [[ -z "$(pkgs_missing "${DESKTOP_PKGS[@]}")" ]] || return 1
  [[ "$(stat -c %U "/home/$AGENT_USER/.config/tigervnc/passwd" 2>/dev/null)" == "$AGENT_USER" ]] || return 1
  systemctl is-active --quiet vnc-agent || return 1
  listens_on_loopback_only 5901
}

apply() {
  apt_install "${DESKTOP_PKGS[@]}"
  # Screen lockers would lock the agent out of its own desktop.
  apt-get purge -y light-locker xfce4-screensaver 2>/dev/null || true

  # TigerVNC >= 1.14 keeps its files in ~/.config/tigervnc and tries to migrate ~/.vnc there.
  local home="/home/$AGENT_USER" vncdir="/home/$AGENT_USER/.config/tigervnc"
  agent_fix_home_owner
  rm -rf "$home/.vnc"
  agent_mkdir -m 700 "$vncdir"
  printf '%s\n' "$VNC_PASSWORD" | vncpasswd -f > "$vncdir/passwd"
  chown "$AGENT_USER:$AGENT_USER" "$vncdir/passwd"; chmod 600 "$vncdir/passwd"
  install -m 755 -o "$AGENT_USER" -g "$AGENT_USER" "$SA_REPO/templates/desktop/xstartup" "$vncdir/xstartup"

  # XFCE: no screensaver / DPMS blanking, no power manager popups.
  agent_mkdir "$home/.config/xfce4/xfconf/xfce-perchannel-xml"
  install -m 644 -o "$AGENT_USER" -g "$AGENT_USER" \
    "$SA_REPO/templates/desktop/xfce4-power-manager.xml" \
    "$home/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml"

  render "$SA_REPO/templates/desktop/vnc-agent.service" "$UNIT" '${AGENT_USER} ${VNC_GEOMETRY}' || true
  systemctl daemon-reload
  systemctl enable vnc-agent
  systemctl restart vnc-agent
  wait_for "VNC na 127.0.0.1:5901" 30 bash -c "ss -ltnH 'sport = :5901' | grep -q ."
}
