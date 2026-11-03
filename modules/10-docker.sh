#!/usr/bin/env bash
# Docker Engine + compose plugin from Docker's official apt repo.

DESCRIPTION="Docker Engine + compose plugin"

check() {
  command -v docker &>/dev/null || return 1
  docker compose version &>/dev/null || return 1
  systemctl is-active --quiet docker || return 1
  id -nG "$AGENT_USER" | grep -qw docker || return 1
}

apply() {
  if ! command -v docker &>/dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  # Keep container logs from filling the disk.
  if [[ ! -f /etc/docker/daemon.json ]]; then
    cat > /etc/docker/daemon.json <<'EOF'
{ "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "5" } }
EOF
    systemctl restart docker
  fi
  systemctl enable --now docker
  usermod -aG docker "$AGENT_USER"
}
