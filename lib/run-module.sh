#!/usr/bin/env bash
# Runs one module as its own process so `set -e` is fully in effect inside apply()
# (errexit is silently disabled in a subshell that the caller tests with if/||).
#   run-module.sh <module-file> <status_only 0|1> <force 0|1>

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

file="$1"; status_only="${2:-0}"; force="${3:-0}"
export SA_MODULE; SA_MODULE="$(basename "$file" .sh)"

# shellcheck disable=SC1090
source "$file"
if [[ -f "$SA_ENV_FILE" ]]; then load_env; fi

if check; then
  if ((status_only)); then ok "$DESCRIPTION"; exit 0; fi
  if ((force)); then log "--force: ponovo primenjujem"; else ok "već urađeno — $DESCRIPTION"; exit 0; fi
elif ((status_only)); then
  warn "NIJE urađeno — $DESCRIPTION"; exit 0
fi

log "primenjujem — $DESCRIPTION"
apply
if [[ -f "$SA_ENV_FILE" ]]; then load_env; fi
check || die "apply je završen ali check i dalje ne prolazi"
ok "gotovo — $DESCRIPTION"
