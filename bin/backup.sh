#!/usr/bin/env bash
# Nightly backup into the S3 bucket (Garage on this server):
#   backups/pg/<ts>.dump        — pg_dump -Fc of the whole database
#   backups/cases/<ts>.tar.zst  — case folders (agent's long-term memory, incl. .git)
#   backups/shared/<ts>.tar.zst — shared platform notes
# Old backups are pruned after BACKUP_RETENTION_DAYS.
# NOTE: the bucket lives on the same server → this protects against mistakes, not disk loss.
#       Hetzner Backups (server snapshots) cover the server itself; copy off-site when possible.

source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
SA_MODULE=backup
require_root
load_env

ts="$(date +%Y-%m-%dT%H-%M)"
dest="s3:${S3_BUCKET}/backups"

log "pg_dump → $dest/pg/$ts.dump"
compose exec -T postgres pg_dump -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  | rclone rcat "$dest/pg/$ts.dump"

for dir in cases shared; do
  if [[ -d "$SA_DATA/$dir" ]] && [[ -n "$(ls -A "$SA_DATA/$dir")" ]]; then
    log "tar $SA_DATA/$dir → $dest/$dir/$ts.tar.zst"
    tar -C "$SA_DATA" --zstd -cf - "$dir" | rclone rcat "$dest/$dir/$ts.tar.zst"
  fi
done

log "brišem backup-e starije od ${BACKUP_RETENTION_DAYS} dana"
rclone delete "$dest" --min-age "${BACKUP_RETENTION_DAYS}d"

ok "backup $ts gotov"
