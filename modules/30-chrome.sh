#!/usr/bin/env bash
# Google Chrome (stable) with a persistent dedicated profile, auto-started in the agent desktop.
#
# - Profile: /home/agent/chrome-profile  (logins to IG/Reddit/... live here, survive restarts)
# - CDP on 127.0.0.1:9222 so DevTools/Playwright MCP can attach to the SAME browser.
#   Chrome ≥136 refuses --remote-debugging-port on the default profile dir, hence the
#   dedicated --user-data-dir.
# - The Claude in Chrome extension is installed manually from the VNC desktop (needs login).

DESCRIPTION="Google Chrome + trajni profil + autostart (CDP 127.0.0.1:9222)"

LAUNCHER=/usr/local/bin/agent-chrome

check() {
  command -v google-chrome-stable &>/dev/null || return 1
  [[ -x "$LAUNCHER" ]] || return 1
  [[ -f "/home/$AGENT_USER/.config/autostart/agent-chrome.desktop" ]] || return 1
  [[ -d "/home/$AGENT_USER/chrome-profile" ]] || return 1
}

apply() {
  if ! command -v google-chrome-stable &>/dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor --yes -o /etc/apt/keyrings/google-chrome.gpg
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list
    apt-get update -y
    apt_install google-chrome-stable
    # The .deb re-adds its own list file; keep a single source.
    rm -f /etc/apt/sources.list.d/google-chrome.list.save
  fi

  install -m 755 "$SA_REPO/templates/desktop/agent-chrome" "$LAUNCHER"

  local home="/home/$AGENT_USER"
  agent_mkdir -m 700 "$home/chrome-profile"
  agent_mkdir "$home/.config/autostart" "$home/Desktop"
  install -m 644 -o "$AGENT_USER" -g "$AGENT_USER" "$SA_REPO/templates/desktop/agent-chrome.desktop" "$home/.config/autostart/agent-chrome.desktop"
  install -m 755 -o "$AGENT_USER" -g "$AGENT_USER" "$SA_REPO/templates/desktop/agent-chrome.desktop" "$home/Desktop/agent-chrome.desktop"

  # Start it now if the desktop is already up.
  if systemctl is-active --quiet vnc-agent && ! pgrep -u "$AGENT_USER" -f chrome-profile &>/dev/null; then
    sudo -u "$AGENT_USER" -H DISPLAY=:1 setsid "$LAUNCHER" &>/dev/null < /dev/null &
  fi
}
