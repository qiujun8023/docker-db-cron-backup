#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_SCRIPT="$PROJECT_ROOT/scripts/backup.sh"
ENTRYPOINT_SCRIPT="$PROJECT_ROOT/scripts/entrypoint.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/docker-db-cron-backup.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

TIMESTAMP=20260917013000
pass_count=0

pass() {
  printf 'PASS %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail_test() {
  printf 'FAIL %s: %s\n' "$1" "$2" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail_test "$2" "missing file $1"
}

assert_missing() {
  [[ ! -e "$1" ]] || fail_test "$2" "unexpected file $1"
}

assert_empty_dir() {
  if [[ -n "$(find "$1" -mindepth 1 -print -quit)" ]]; then
    fail_test "$2" "directory is not empty: $1"
  fi
}

assert_contains() {
  grep -q -- "$2" "$1" || fail_test "$3" "$1 does not contain $2"
}

create_mocks() {
  local root="$1"
  mkdir -p "$root/bin" "$root/s3" "$root/state" "$root/tmp"

  cat > "$root/bin/mysql" <<'MOCK'
#!/usr/bin/env bash
printf '%b' "${MOCK_DATABASES:-information_schema\nmysql\nperformance_schema\nsys\napp\nanalytics\n}"
MOCK

  cat > "$root/bin/mysqldump" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_DB_ARGS_LOG"
database="${!#}"
if [[ "${MOCK_FAIL_DATABASE:-}" == "$database" ]]; then
  exit 23
fi
printf '%s\n' "CREATE DATABASE IF NOT EXISTS \`$database\`;" "USE \`$database\`;" "SELECT '$database';"
MOCK

  cat > "$root/bin/psql" <<'MOCK'
#!/usr/bin/env bash
printf 'PGHOST=%s PGPORT=%s PGUSER=%s PGSSLMODE=%s PGDATABASE=%s\n' \
  "$PGHOST" "$PGPORT" "$PGUSER" "$PGSSLMODE" "$PGDATABASE" >> "$MOCK_DB_ARGS_LOG"
printf '%b' "${MOCK_DATABASES-template1\napp\nanalytics\n}"
MOCK

  cat > "$root/bin/pg_dump" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_DB_ARGS_LOG"
for arg in "$@"; do
  case "$arg" in
    --dbname=*) database="${arg#--dbname=}" ;;
    --file=*) file="${arg#--file=}" ;;
  esac
done
if [[ "${MOCK_FAIL_DATABASE:-}" == "$database" ]]; then
  exit 23
fi
printf 'PGDMP %s\n' "$database" > "$file"
MOCK

  cat > "$root/bin/pg_dumpall" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_DB_ARGS_LOG"
printf '%s\n' 'CREATE ROLE app;'
MOCK

  cat > "$root/bin/pg_restore" <<'MOCK'
#!/usr/bin/env bash
archive="${!#}"
grep -q '^PGDMP ' "$archive" || exit 1
[[ "$(cat "$archive")" != "PGDMP ${MOCK_CORRUPT_DATABASE:-}" ]]
MOCK

  cp "$PROJECT_ROOT/tests/fake-aws.sh" "$root/bin/aws"

  chmod +x "$root"/bin/*
}

run_backup() {
  local root="$1"
  local engine="$2"
  shift 2
  env \
    PATH="$root/bin:$PATH" \
    TMPDIR="$root/tmp" \
    STATE_DIR="$root/state" \
    BACKUP_LOCK_DISABLED=true \
    BACKUP_TIMESTAMP="$TIMESTAMP" \
    DB_ENGINE="$engine" \
    DB_HOST=db \
    DB_USER=backup \
    DB_PASSWORD=secret \
    S3_ENDPOINT=https://s3.example.test \
    S3_BUCKET=db-backups \
    AWS_ACCESS_KEY_ID=access \
    AWS_SECRET_ACCESS_KEY=secret \
    MOCK_AWS_LOG="$root/aws.log" \
    MOCK_AWS_ARGS_LOG="$root/aws-args.log" \
    MOCK_DB_ARGS_LOG="$root/db-args.log" \
    MOCK_S3_DIR="$root/s3" \
    "$@" \
    bash "$BACKUP_SCRIPT"
}

test_mysql_happy_path() {
  local name=mysql_happy_path
  local root="$TEST_ROOT/$name"
  create_mocks "$root"

  run_backup "$root" mysql

  assert_file "$root/s3/app/$TIMESTAMP.sql.gz" "$name"
  assert_file "$root/s3/analytics/$TIMESTAMP.sql.gz" "$name"
  assert_file "$root/state/last-success" "$name"
  assert_missing "$root/s3/mysql" "$name"
  assert_missing "$root/s3/_globals" "$name"
  assert_empty_dir "$root/tmp" "$name"
  gzip -dc "$root/s3/app/$TIMESTAMP.sql.gz" | head -n 1 | grep -q '^CREATE DATABASE' \
    || fail_test "$name" "unexpected dump content"
  assert_contains "$root/aws-args.log" '--endpoint-url https://s3.example.test' "$name"
  assert_contains "$root/db-args.log" '--host=db --port=3306 --user=backup --protocol=TCP --ssl-mode=PREFERRED' "$name"
  pass "$name"
}

test_mysql_ssl_mode() {
  local name=mysql_ssl_mode
  local root="$TEST_ROOT/$name"
  create_mocks "$root"

  run_backup "$root" mysql DB_DATABASES=app DB_SSL_MODE=verify-full DB_PORT=3307

  assert_contains "$root/db-args.log" '--port=3307' "$name"
  assert_contains "$root/db-args.log" '--ssl-mode=VERIFY_IDENTITY' "$name"
  pass "$name"
}

test_postgres_happy_path() {
  local name=postgres_happy_path
  local root="$TEST_ROOT/$name"
  create_mocks "$root"

  run_backup "$root" postgres DB_SSL_MODE=required

  assert_file "$root/s3/_globals/$TIMESTAMP.sql.gz" "$name"
  assert_file "$root/s3/app/$TIMESTAMP.dump" "$name"
  assert_file "$root/s3/analytics/$TIMESTAMP.dump" "$name"
  assert_missing "$root/s3/template1" "$name"
  assert_file "$root/state/last-success" "$name"
  assert_empty_dir "$root/tmp" "$name"
  gzip -dc "$root/s3/_globals/$TIMESTAMP.sql.gz" | grep -q '^CREATE ROLE' \
    || fail_test "$name" "unexpected globals content"
  assert_contains "$root/db-args.log" 'PGHOST=db PGPORT=5432 PGUSER=backup PGSSLMODE=require PGDATABASE=postgres' "$name"
  assert_contains "$root/db-args.log" '--globals-only --no-role-passwords' "$name"
  assert_contains "$root/db-args.log" '--format=custom --compress=6 --dbname=app' "$name"
  pass "$name"
}

test_postgres_corrupt_dump() {
  local name=postgres_corrupt_dump
  local root="$TEST_ROOT/$name"
  create_mocks "$root"

  if run_backup "$root" postgres DB_DATABASES=app,analytics MOCK_CORRUPT_DATABASE=app; then
    fail_test "$name" "backup unexpectedly succeeded"
  fi

  assert_missing "$root/s3/app" "$name"
  assert_file "$root/s3/analytics/$TIMESTAMP.dump" "$name"
  assert_file "$root/state/last-failure" "$name"
  assert_empty_dir "$root/tmp" "$name"
  pass "$name"
}

test_no_user_databases() {
  local name=no_user_databases
  local root="$TEST_ROOT/$name"
  create_mocks "$root"

  run_backup "$root" mysql MOCK_DATABASES='information_schema\nmysql\nperformance_schema\nsys\n'

  assert_file "$root/state/last-success" "$name"
  assert_missing "$root/state/last-failure" "$name"
  assert_missing "$root/aws.log" "$name"
  assert_empty_dir "$root/s3" "$name"
  assert_empty_dir "$root/tmp" "$name"
  pass "$name"
}

test_postgres_no_user_databases() {
  local name=postgres_no_user_databases
  local root="$TEST_ROOT/$name"
  create_mocks "$root"

  run_backup "$root" postgres MOCK_DATABASES=''

  assert_file "$root/state/last-success" "$name"
  assert_empty_dir "$root/s3" "$name"
  pass "$name"
}

test_s3_prefix() {
  local name=s3_prefix
  local root="$TEST_ROOT/$name"
  create_mocks "$root"

  run_backup "$root" mysql DB_DATABASES=app S3_PREFIX=/prod/db-01/

  assert_file "$root/s3/prod/db-01/app/$TIMESTAMP.sql.gz" "$name"
  pass "$name"
}

test_invalid_s3_prefix() {
  local name=invalid_s3_prefix
  local root="$TEST_ROOT/$name"
  create_mocks "$root"

  if run_backup "$root" mysql DB_DATABASES=app S3_PREFIX='a//b'; then
    fail_test "$name" "backup unexpectedly succeeded"
  fi

  assert_file "$root/state/last-failure" "$name"
  pass "$name"
}

test_without_endpoint() {
  local name=without_endpoint
  local root="$TEST_ROOT/$name"
  create_mocks "$root"

  run_backup "$root" mysql DB_DATABASES=app S3_ENDPOINT=

  if grep -q -- '--endpoint-url' "$root/aws-args.log"; then
    fail_test "$name" "endpoint should not be passed to aws"
  fi
  pass "$name"
}

test_partial_failure() {
  local name=partial_failure
  local root="$TEST_ROOT/$name"
  create_mocks "$root"

  if run_backup "$root" mysql DB_DATABASES=app,broken MOCK_FAIL_DATABASE=broken; then
    fail_test "$name" "backup unexpectedly succeeded"
  fi

  assert_file "$root/s3/app/$TIMESTAMP.sql.gz" "$name"
  assert_file "$root/state/last-failure" "$name"
  assert_missing "$root/state/last-success" "$name"
  assert_missing "$root/s3/broken" "$name"
  assert_empty_dir "$root/tmp" "$name"
  pass "$name"
}

test_unsupported_database_name() {
  local name=unsupported_database_name
  local root="$TEST_ROOT/$name"
  create_mocks "$root"

  if run_backup "$root" mysql MOCK_DATABASES='app\nbad name\n_globals\n'; then
    fail_test "$name" "backup unexpectedly succeeded"
  fi

  assert_file "$root/s3/app/$TIMESTAMP.sql.gz" "$name"
  assert_missing "$root/s3/_globals" "$name"
  assert_file "$root/state/last-failure" "$name"
  pass "$name"
}

test_only_unsupported_database_names() {
  local name=only_unsupported_database_names
  local root="$TEST_ROOT/$name"
  create_mocks "$root"

  if run_backup "$root" mysql MOCK_DATABASES='bad name\n'; then
    fail_test "$name" "backup unexpectedly succeeded"
  fi

  assert_file "$root/state/last-failure" "$name"
  assert_missing "$root/state/last-success" "$name"
  pass "$name"
}

test_remote_size_mismatch() {
  local name=remote_size_mismatch
  local root="$TEST_ROOT/$name"
  create_mocks "$root"

  if run_backup "$root" mysql DB_DATABASES=app MOCK_SIZE_MISMATCH=true; then
    fail_test "$name" "backup unexpectedly succeeded"
  fi

  assert_file "$root/state/last-failure" "$name"
  assert_empty_dir "$root/tmp" "$name"
  pass "$name"
}

test_missing_bucket() {
  local name=missing_bucket
  local root="$TEST_ROOT/$name"
  create_mocks "$root"

  if run_backup "$root" mysql DB_DATABASES=app S3_BUCKET=; then
    fail_test "$name" "backup unexpectedly succeeded"
  fi

  assert_missing "$root/aws.log" "$name"
  pass "$name"
}

test_invalid_ssl_mode() {
  local name=invalid_ssl_mode
  local root="$TEST_ROOT/$name"
  create_mocks "$root"

  if run_backup "$root" mysql DB_DATABASES=app DB_SSL_MODE=REQUIRED; then
    fail_test "$name" "backup unexpectedly succeeded"
  fi

  assert_missing "$root/aws.log" "$name"
  pass "$name"
}

test_invalid_engine() {
  local name=invalid_engine
  local root="$TEST_ROOT/$name"
  create_mocks "$root"

  if run_backup "$root" mariadb DB_DATABASES=app; then
    fail_test "$name" "backup unexpectedly succeeded"
  fi

  assert_file "$root/state/last-failure" "$name"
  assert_missing "$root/aws.log" "$name"
  pass "$name"
}

run_entrypoint() {
  local root="$1"
  shift
  env \
    STATE_DIR="$root/state" \
    CRON_DIR="$root/crontabs" \
    CROND_BIN="$root/bin/crond" \
    "$@" \
    bash "$ENTRYPOINT_SCRIPT"
}

create_crond_mock() {
  local root="$1"
  mkdir -p "$root/bin"
  cat > "$root/bin/crond" <<MOCK
#!/usr/bin/env bash
printf '%s\\n' "\$*" > "$root/crond.args"
MOCK
  chmod +x "$root/bin/crond"
}

test_entrypoint_crontab() {
  local name=entrypoint_crontab
  local root="$TEST_ROOT/$name"
  create_crond_mock "$root"

  run_entrypoint "$root" BACKUP_CRON='*/15 1-5 * * 1,3'

  [[ "$(cat "$root/crontabs/root")" == "*/15 1-5 * * 1,3 $BACKUP_SCRIPT >/proc/1/fd/1 2>/proc/1/fd/2" ]] \
    || fail_test "$name" "unexpected crontab: $(cat "$root/crontabs/root")"
  [[ "$(cat "$root/crond.args")" == "-f -l 8 -L /dev/stderr -c $root/crontabs" ]] \
    || fail_test "$name" "unexpected crond args: $(cat "$root/crond.args")"
  assert_file "$root/state/started-at" "$name"
  pass "$name"
}

test_entrypoint_invalid_cron() {
  local name=entrypoint_invalid_cron
  local root="$TEST_ROOT/$name"
  local expression
  create_crond_mock "$root"

  for expression in '0 3 * *' '0 3 * * * *' $'0 3 * * *\n* * * * *' '0 3 * * ;id'; do
    if run_entrypoint "$root" BACKUP_CRON="$expression" 2>/dev/null; then
      fail_test "$name" "accepted invalid expression: $expression"
    fi
  done

  [[ ! -e "$root/crond.args" ]] || fail_test "$name" "crond should not start"
  [[ ! -e "$root/crontabs/root" ]] || fail_test "$name" "crontab should not be written"
  pass "$name"
}

test_healthcheck() {
  local name=healthcheck
  local root="$TEST_ROOT/$name"
  local now
  mkdir -p "$root/state"
  now="$(date +%s)"

  printf '%s\n' "$now" > "$root/state/started-at"
  STATE_DIR="$root/state" HEALTHCHECK_MAX_AGE_SECONDS=60 \
    bash "$PROJECT_ROOT/scripts/healthcheck.sh" \
    || fail_test "$name" "fresh container should be healthy"

  printf '%s\n' "$now" > "$root/state/last-success"
  printf '%s\n' "$((now + 1))" > "$root/state/last-failure"
  if STATE_DIR="$root/state" HEALTHCHECK_MAX_AGE_SECONDS=60 \
      bash "$PROJECT_ROOT/scripts/healthcheck.sh"; then
    fail_test "$name" "newer failure should be unhealthy"
  fi

  printf '%s\n' "$((now + 2))" > "$root/state/last-success"
  STATE_DIR="$root/state" HEALTHCHECK_MAX_AGE_SECONDS=60 \
    bash "$PROJECT_ROOT/scripts/healthcheck.sh" \
    || fail_test "$name" "newer success should recover health"
  pass "$name"
}

test_mysql_happy_path
test_mysql_ssl_mode
test_postgres_happy_path
test_postgres_corrupt_dump
test_no_user_databases
test_postgres_no_user_databases
test_s3_prefix
test_invalid_s3_prefix
test_without_endpoint
test_partial_failure
test_unsupported_database_name
test_only_unsupported_database_names
test_remote_size_mismatch
test_missing_bucket
test_invalid_ssl_mode
test_invalid_engine
test_entrypoint_crontab
test_entrypoint_invalid_cron
test_healthcheck

printf '%s tests passed\n' "$pass_count"
