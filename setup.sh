#!/usr/bin/env bash
# social-agent server setup — idempotent orchestrator.
#
#   sudo ./setup.sh               # run every module that is not yet done
#   sudo ./setup.sh --status      # only show what is done / missing
#   sudo ./setup.sh 20-desktop    # run selected modules (prefix match)
#   sudo ./setup.sh --force 30    # re-apply a module even if its check passes
#
# Every module in modules/ defines:
#   DESCRIPTION="..."
#   check()  -> exit 0 when the module's desired state is already in place
#   apply()  -> bring the server to that state (must be safe to re-run)
# Modules prefixed "opt-" run only when named explicitly.

source "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

status_only=0; force=0; selected=()
while (($#)); do
  case "$1" in
    --status|-s) status_only=1 ;;
    --force|-f)  force=1 ;;
    -h|--help)   usage 0 ;;
    -*)          usage 1 ;;
    *)           selected+=("$1") ;;
  esac
  shift
done

require_root

modules=()
for f in "$SA_REPO"/modules/*.sh; do
  name="$(basename "$f" .sh)"
  if ((${#selected[@]})); then
    for s in "${selected[@]}"; do [[ "$name" == "$s"* || "$name" == *"-$s"* ]] && modules+=("$f") && break; done
  else
    [[ "$name" == opt-* ]] || modules+=("$f")
  fi
done
((${#modules[@]})) || die "nijedan modul ne odgovara: ${selected[*]}"

failed=()
for m in "${modules[@]}"; do
  if ! bash "$SA_REPO/lib/run-module.sh" "$m" "$status_only" "$force"; then
    failed+=("$(basename "$m" .sh)")
    warn "modul $(basename "$m" .sh) nije uspeo — zaustavljam (sledeći moduli zavise od prethodnih)"
    break
  fi
done

echo
if ((${#failed[@]})); then
  die "neuspešno: ${failed[*]} — popravi i ponovo pokreni ./setup.sh (urađeni moduli se preskaču)"
fi
((status_only)) || ok "setup završen. Sledeći koraci: docs/FIRST-LOGIN.md"
