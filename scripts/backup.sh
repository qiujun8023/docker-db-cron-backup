#!/usr/bin/env bash

set -Eeuo pipefail

export LC_ALL=C
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLOBALS_NAME=_globals

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"
}

fail() {
  log "ERROR: $*" >&2
  return 1
}

require_value() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    fail "$name is required"
    return 1
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "required command not found: $1"
    return 1
  fi
}

write_epoch() {
  local destination="$1"
  local temporary="${destination}.tmp.$$"
  date +%s > "$temporary"
  mv -f "$temporary" "$destination"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

validate_database_name() {
  [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.\$-]*$ && "$1" != "$GLOBALS_NAME" ]]
}

local_file_size() {
  wc -c < "$1" | tr -d '[:space:]'
}

collect_databases() {
  local destination="$1"

  if [[ -n "${DB_DATABASES:-}" ]]; then
    printf '%s\n' "$DB_DATABASES" | tr ',' '\n' > "$destination"
    return
  fi

  if ! engine_list_databases > "$destination"; then
    fail "could not list $DB_ENGINE databases"
    return 1
  fi
}

# Runs the producer to write a verified local file, then uploads it and
# compares the stored object size with the local file.
backup_object() {
  local label="$1"
  local key="$2"
  shift 2
  local output="${WORK_DIR}/${key//\//_}"
  local remote_size
  local local_size

  log "Dumping $label"
  if ! "$@" "$output"; then
    rm -f -- "$output"
    fail "dump failed for $label"
    return 1
  fi

  log "Uploading s3://${S3_BUCKET}/${key}"
  if ! "$AWS_BIN" "${AWS_ARGS[@]}" s3 cp \
      "$output" "s3://${S3_BUCKET}/${key}" \
      --only-show-errors; then
    rm -f -- "$output"
    fail "S3 upload failed for $label"
    return 1
  fi

  local_size="$(local_file_size "$output")"
  rm -f -- "$output"

  if ! remote_size="$("$AWS_BIN" "${AWS_ARGS[@]}" s3api head-object \
      --bucket "$S3_BUCKET" \
      --key "$key" \
      --query ContentLength \
      --output text)"; then
    fail "could not verify uploaded object for $label"
    return 1
  fi
  remote_size="$(trim "$remote_size")"

  if [[ "$local_size" != "$remote_size" ]]; then
    fail "uploaded size mismatch for $label: local=$local_size remote=$remote_size"
    return 1
  fi

  log "Completed $label"
}

DB_ENGINE="${DB_ENGINE:-}"
DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-}"
DB_USER="${DB_USER:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_SSL_MODE="${DB_SSL_MODE:-preferred}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_REGION="${S3_REGION:-us-east-1}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-6}"
STATE_DIR="${STATE_DIR:-/var/lib/db-backup}"
ENGINE_DIR="${ENGINE_DIR:-$SCRIPT_DIR/engines}"
AWS_BIN="${AWS_BIN:-aws}"

mkdir -p "$STATE_DIR"
WORK_DIR=""

on_exit() {
  local status=$?
  trap - EXIT
  if [[ -n "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR" 2>/dev/null || true
  fi
  if (( status != 0 )); then
    write_epoch "$STATE_DIR/last-failure" 2>/dev/null || true
  fi
  exit "$status"
}
trap on_exit EXIT

case "$DB_ENGINE" in
  mysql|postgres) ;;
  *)
    fail "DB_ENGINE must be mysql or postgres"
    exit 1
    ;;
esac
# shellcheck source-path=SCRIPTDIR source=engines/mysql.sh
source "$ENGINE_DIR/$DB_ENGINE.sh"
DB_PORT="${DB_PORT:-$ENGINE_DEFAULT_PORT}"

require_value DB_HOST
require_value DB_USER
require_value DB_PASSWORD
require_value S3_BUCKET
require_value AWS_ACCESS_KEY_ID
require_value AWS_SECRET_ACCESS_KEY

S3_PREFIX="${S3_PREFIX#/}"
S3_PREFIX="${S3_PREFIX%/}"
if [[ -n "$S3_PREFIX" && ! "$S3_PREFIX" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]]; then
  fail "S3_PREFIX contains unsupported characters"
  exit 1
fi
S3_KEY_PREFIX="${S3_PREFIX:+${S3_PREFIX}/}"

if [[ ! "$DB_PORT" =~ ^[0-9]+$ ]]; then
  fail "DB_PORT must be numeric"
  exit 1
fi
if [[ ! "$COMPRESSION_LEVEL" =~ ^[1-9]$ ]]; then
  fail "COMPRESSION_LEVEL must be between 1 and 9"
  exit 1
fi
case "$DB_SSL_MODE" in
  disabled|preferred|required|verify-ca|verify-full) ;;
  *)
    fail "DB_SSL_MODE must be disabled, preferred, required, verify-ca or verify-full"
    exit 1
    ;;
esac

engine_require_commands
require_command "$AWS_BIN"
require_command gzip

if [[ "${BACKUP_LOCK_DISABLED:-false}" != "true" ]]; then
  require_command flock
  exec 9> "$STATE_DIR/backup.lock"
  if ! flock -n 9; then
    fail "another backup is already running"
    exit 1
  fi
fi
write_epoch "$STATE_DIR/last-attempt"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/db-backup.XXXXXX")"

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$S3_REGION"

if [[ -z "${AWS_CONFIG_FILE:-}" ]]; then
  AWS_CONFIG_FILE="$WORK_DIR/aws-config"
  {
    printf '[default]\nregion = %s\n' "$S3_REGION"
    if [[ -n "$S3_ENDPOINT" ]]; then
      printf 'request_checksum_calculation = when_required\n'
      printf 'response_checksum_validation = when_required\n'
      printf 's3 =\n  addressing_style = path\n'
    fi
  } > "$AWS_CONFIG_FILE"
  export AWS_CONFIG_FILE
fi

AWS_ARGS=(--region "$S3_REGION")
if [[ -n "$S3_ENDPOINT" ]]; then
  AWS_ARGS+=(--endpoint-url "$S3_ENDPOINT")
fi

engine_configure

TIMESTAMP="${BACKUP_TIMESTAMP:-$(date +%Y%m%d%H%M%S)}"
if [[ ! "$TIMESTAMP" =~ ^[0-9]{14}$ ]]; then
  fail "backup timestamp must use YYYYMMDDHHmmss"
  exit 1
fi

DATABASE_LIST="$WORK_DIR/databases"
collect_databases "$DATABASE_LIST"

failures=0
DATABASES=()
while IFS= read -r database || [[ -n "$database" ]]; do
  database="$(trim "${database%$'\r'}")"
  [[ -z "$database" ]] && continue
  engine_is_system_database "$database" && continue
  if ! validate_database_name "$database"; then
    log "ERROR: skipping unsupported database name: $database" >&2
    failures=$((failures + 1))
    continue
  fi
  DATABASES+=("$database")
done < "$DATABASE_LIST"

if (( ${#DATABASES[@]} == 0 && failures == 0 )); then
  write_epoch "$STATE_DIR/last-success"
  rm -f "$STATE_DIR/last-failure"
  log "No user databases found; nothing to back up"
  exit 0
fi

log "Starting $DB_ENGINE backup; databases=${#DATABASES[@]}"
if declare -F engine_dump_globals >/dev/null; then
  if ! backup_object "cluster globals" \
      "${S3_KEY_PREFIX}${GLOBALS_NAME}/${TIMESTAMP}.sql.gz" \
      engine_dump_globals; then
    failures=$((failures + 1))
  fi
fi
for database in "${DATABASES[@]}"; do
  if ! backup_object "database $database" \
      "${S3_KEY_PREFIX}${database}/${TIMESTAMP}.${ENGINE_EXTENSION}" \
      engine_dump "$database"; then
    failures=$((failures + 1))
  fi
done

if (( failures > 0 )); then
  fail "$failures backup item(s) failed"
  exit 1
fi

write_epoch "$STATE_DIR/last-success"
rm -f "$STATE_DIR/last-failure"
log "Backup completed successfully"
