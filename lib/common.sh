#!/usr/bin/env bash
# Shared helpers for setup.sh and every module. Sourced, never executed.

set -Eeuo pipefail

SA_REPO="${SA_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SA_ENV_FILE="${SA_ENV_FILE:-/etc/social-agent/.env}"

c_reset=$'\e[0m'; c_dim=$'\e[2m'; c_green=$'\e[32m'; c_yellow=$'\e[33m'; c_red=$'\e[31m'; c_blue=$'\e[34m'

log()  { printf '%s[%s]%s %s\n' "$c_blue" "${SA_MODULE:-setup}" "$c_reset" "$*"; }
ok()   { printf '%s[%s] ✓%s %s\n' "$c_green" "${SA_MODULE:-setup}" "$c_reset" "$*"; }
warn() { printf '%s[%s] !%s %s\n' "$c_yellow" "${SA_MODULE:-setup}" "$c_reset" "$*" >&2; }
die()  { printf '%s[%s] ✗%s %s\n' "$c_red" "${SA_MODULE:-setup}" "$c_reset" "$*" >&2; exit 1; }
dim()  { printf '%s%s%s\n' "$c_dim" "$*" "$c_reset"; }

require_root() { [[ $EUID -eq 0 ]] || die "pokreni kao root (sudo $0)"; }

# Load /etc/social-agent/.env into the environment (exported).
load_env() {
  [[ -f "$SA_ENV_FILE" ]] || die "nema $SA_ENV_FILE — prvo pokreni modul 01-env"
  set -a
  # shellcheck disable=SC1090
  source "$SA_ENV_FILE"
  set +a
}

env_has() { [[ -f "$SA_ENV_FILE" ]] && grep -qE "^$1=.+" "$SA_ENV_FILE"; }

# Set KEY=VALUE in the env file (replace or append). Values must not contain newlines.
env_set() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" "$SA_ENV_FILE"; then
    local tmp; tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k{print k"="v; next} {print}' "$SA_ENV_FILE" > "$tmp"
    cat "$tmp" > "$SA_ENV_FILE"; rm -f "$tmp"
  else
    printf '%s=%s\n' "$key" "$value" >> "$SA_ENV_FILE"
  fi
}

rand_hex()   { openssl rand -hex "${1:-32}"; }
rand_alnum() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-32}"; }

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
pkgs_missing() { local p m=(); for p in "$@"; do pkg_installed "$p" || m+=("$p"); done; echo "${m[*]:-}"; }

apt_install() {
  local missing; missing="$(pkgs_missing "$@")"
  [[ -z "$missing" ]] && return 0
  log "apt install $missing"
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $missing
}

user_exists() { id "$1" &>/dev/null; }

# Run a command as the agent user with a login shell (HOME, PATH set properly).
as_agent() { sudo -u "${AGENT_USER:-agent}" -H bash -lc "$*"; }

# Install a file from templates with envsubst, only replacing ${VARS} we pass explicitly.
render() {
  local src="$1" dst="$2" vars="$3" mode="${4:-0644}" owner="${5:-root:root}"
  local tmp; tmp="$(mktemp)"
  envsubst "$vars" < "$src" > "$tmp"
  if [[ -f "$dst" ]] && cmp -s "$tmp" "$dst"; then rm -f "$tmp"; return 1; fi
  install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$dst"
  rm -f "$tmp"
  return 0
}

compose() {
  docker compose --project-name social-agent \
    --env-file "$SA_ENV_FILE" \
    -f "$SA_REPO/compose/docker-compose.yml" "$@"
}

wait_for() {
  local desc="$1" tries="${2:-60}"; shift 2
  local i
  for ((i = 0; i < tries; i++)); do
    if "$@" &>/dev/null; then return 0; fi
    sleep 2
  done
  die "timeout čekajući: $desc"
}

# True when something listens on PORT and every listener is on loopback.
listens_on_loopback_only() {
  local addrs; addrs="$(ss -ltnH "sport = :$1" | awk '{print $4}')"
  [[ -n "$addrs" ]] || return 1
  ! grep -qvE '^(127\.0\.0\.1|\[::1\]):[0-9]+$' <<<"$addrs"
}
