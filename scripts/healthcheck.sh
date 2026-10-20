#!/usr/bin/env bash

set -uo pipefail

MAX_AGE="${HEALTHCHECK_MAX_AGE_SECONDS:-129600}"
STATE_DIR="${STATE_DIR:-/var/lib/db-backup}"

read_epoch() {
  local file="$1"
  local value=0
  if [[ -r "$file" ]]; then
    IFS= read -r value < "$file" || true
  fi
  [[ "$value" =~ ^[0-9]+$ ]] || value=0
  printf '%s' "$value"
}

if [[ ! "$MAX_AGE" =~ ^[1-9][0-9]*$ ]]; then
  exit 1
fi

now="$(date +%s)"
started="$(read_epoch "$STATE_DIR/started-at")"
success="$(read_epoch "$STATE_DIR/last-success")"
failure="$(read_epoch "$STATE_DIR/last-failure")"

if (( failure > success )); then
  exit 1
fi

if (( success > 0 )); then
  (( now - success <= MAX_AGE ))
  exit
fi

if (( started > 0 )); then
  (( now - started <= MAX_AGE ))
  exit
fi

exit 1
