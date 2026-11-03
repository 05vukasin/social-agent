#!/usr/bin/env bash
# Garage (S3-compatible) single node on 127.0.0.1:3900, one bucket, one access key,
# rclone remote "s3" configured for root and the agent user.

DESCRIPTION="Garage S3 (127.0.0.1:3900) + bucket + rclone remote 's3'"

garage() { compose exec -T garage /garage "$@"; }

rclone_conf() {
  cat <<EOF
[s3]
type = s3
provider = Other
access_key_id = ${S3_ACCESS_KEY_ID}
secret_access_key = ${S3_SECRET_ACCESS_KEY}
endpoint = ${S3_ENDPOINT}
region = ${S3_REGION}
force_path_style = true
EOF
}

check() {
  compose ps --status running --services 2>/dev/null | grep -qx garage || return 1
  listens_on_loopback_only 3900 || return 1
  rclone lsf "s3:${S3_BUCKET}" --max-depth 1 &>/dev/null || return 1
  as_agent "rclone lsf s3:${S3_BUCKET} --max-depth 1" &>/dev/null || return 1
}

apply() {
  install -d -m 700 "$SA_DATA/garage" "$SA_DATA/garage/meta" "$SA_DATA/garage/data"
  render "$SA_REPO/templates/garage/garage.toml" "$SA_DATA/garage/garage.toml" \
    '${GARAGE_RPC_SECRET} ${GARAGE_ADMIN_TOKEN} ${S3_REGION}' 0600 || true

  compose pull garage
  compose up -d garage
  wait_for "garage odgovara" 30 compose exec -T garage /garage status

  # Single-node layout (only once — layout version 0 means nothing assigned yet).
  local layout_ver node
  layout_ver="$(garage layout show 2>/dev/null | grep -ioE 'current cluster layout version: *[0-9]+' | grep -oE '[0-9]+$' || echo 0)"
  if [[ "$layout_ver" == 0 ]]; then
    node="$(garage node id -q | cut -d@ -f1)"
    log "layout: dodeljujem čvor ${node:0:16}… kapacitet ${GARAGE_CAPACITY}"
    garage layout assign -z dc1 -c "$GARAGE_CAPACITY" "$node"
    garage layout apply --version 1
  fi

  # Access key with our pre-generated id/secret (so .env stays the single source of truth).
  if ! garage key info "$S3_ACCESS_KEY_ID" &>/dev/null; then
    garage key import --yes -n social-agent "$S3_ACCESS_KEY_ID" "$S3_SECRET_ACCESS_KEY"
  fi
  if ! garage bucket info "$S3_BUCKET" &>/dev/null; then
    garage bucket create "$S3_BUCKET"
  fi
  garage bucket allow --read --write --owner "$S3_BUCKET" --key "$S3_ACCESS_KEY_ID"

  # rclone remote "s3" for root (backups) and agent (screenshots, case sync).
  install -d -m 700 /root/.config/rclone
  rclone_conf > /root/.config/rclone/rclone.conf; chmod 600 /root/.config/rclone/rclone.conf
  local ah="/home/$AGENT_USER"
  install -d -m 700 -o "$AGENT_USER" -g "$AGENT_USER" "$ah/.config" "$ah/.config/rclone"
  rclone_conf > "$ah/.config/rclone/rclone.conf"
  chown "$AGENT_USER:$AGENT_USER" "$ah/.config/rclone/rclone.conf"; chmod 600 "$ah/.config/rclone/rclone.conf"

  wait_for "S3 bucket dostupan" 15 rclone lsf "s3:${S3_BUCKET}" --max-depth 1
}
