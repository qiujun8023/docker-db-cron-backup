#!/usr/bin/env bash

set -Eeuo pipefail

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"
}

valid_cron() {
  local fields=()
  local field

  [[ "$1" != *$'\n'* ]] || return 1
  read -r -a fields <<< "$1"
  (( ${#fields[@]} == 5 )) || return 1
  for field in "${fields[@]}"; do
    [[ "$field" =~ ^[A-Za-z0-9*,/-]+$ ]] || return 1
  done
}

BACKUP_CRON="${BACKUP_CRON:-0 3 * * *}"
BACKUP_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backup.sh"
STATE_DIR="${STATE_DIR:-/var/lib/db-backup}"
CRON_DIR="${CRON_DIR:-/var/spool/cron/crontabs}"
CROND_BIN="${CROND_BIN:-crond}"
crond_pid=""

# Invoked by the signal trap below.
# shellcheck disable=SC2317,SC2329
stop() {
  if [[ -n "$crond_pid" ]]; then
    kill "$crond_pid" 2>/dev/null || true
  fi
}
trap stop TERM INT

if ! valid_cron "$BACKUP_CRON"; then
  log "ERROR: BACKUP_CRON must be a five-field cron expression" >&2
  exit 1
fi

mkdir -p "$STATE_DIR" "$CRON_DIR"
date +%s > "$STATE_DIR/started-at"

printf '%s %s >/proc/1/fd/1 2>/proc/1/fd/2\n' "$BACKUP_CRON" "$BACKUP_SCRIPT" > "$CRON_DIR/root"
chmod 0600 "$CRON_DIR/root"

log "Starting crond; schedule=\"$BACKUP_CRON\" TZ=${TZ:-UTC}"
"$CROND_BIN" -f -l 8 -L /dev/stderr -c "$CRON_DIR" &
crond_pid=$!
status=0
wait "$crond_pid" || status=$?
trap - TERM INT
exit "$status"
