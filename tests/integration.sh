#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${1:-}"
case "$ENGINE" in
  mysql) DB_IMAGE="${DB_IMAGE:-mysql:8.4}"; EXTENSION=sql.gz ;;
  postgres) DB_IMAGE="${DB_IMAGE:-postgres:18}"; EXTENSION=dump ;;
  *)
    printf 'usage: %s mysql|postgres\n' "$0" >&2
    exit 64
    ;;
esac
IMAGE="${IMAGE:-db-cron-backup:$ENGINE-integration}"

NAME="dbb-it-$ENGINE-$$"
NETWORK="$NAME"
DB_CONTAINER="$NAME-db"
SCHEDULER_CONTAINER="$NAME-scheduler"
S3_VOLUME="$NAME-s3"

ROOT_PASSWORD=root-secret
BACKUP_PASSWORD='p"a\ss #;1'
MYSQL_BACKUP_PASSWORD="${BACKUP_PASSWORD//\\/\\\\}"
TIMESTAMP=20260917030000

log() {
  printf '==> %s\n' "$*"
}

fail_test() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "$SCHEDULER_CONTAINER" "$DB_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "$S3_VOLUME" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for() {
  local description="$1"
  local attempt
  shift
  for attempt in $(seq 1 90); do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  fail_test "timed out waiting for $description after $attempt attempts"
}

assert_equal() {
  [[ "$2" == "$3" ]] || fail_test "$1: expected '$3', got '$2'"
}

backup_env() {
  printf '%s\n' \
    "--network=$NETWORK" \
    "--volume=$PROJECT_ROOT/tests/fake-aws.sh:/opt/fake-aws:ro" \
    "--volume=$S3_VOLUME:/fake-s3" \
    "-e" "DB_HOST=$DB_CONTAINER" \
    "-e" "DB_USER=backup" \
    "-e" "DB_PASSWORD=$BACKUP_PASSWORD" \
    "-e" "S3_BUCKET=db-backups" \
    "-e" "AWS_ACCESS_KEY_ID=integration" \
    "-e" "AWS_SECRET_ACCESS_KEY=integration-secret" \
    "-e" "AWS_BIN=/opt/fake-aws" \
    "-e" "MOCK_S3_DIR=/fake-s3"
}

s3_volume() {
  local command="$1"
  shift
  docker run --rm --volume "$S3_VOLUME:/fake-s3:ro" --entrypoint "$command" "$IMAGE" "$@"
}

mysql_root() {
  docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" "$DB_CONTAINER" \
    mysql --protocol=TCP --host=127.0.0.1 --user=root "$@"
}

mysql_value() {
  mysql_root --batch --skip-column-names --execute="$1"
}

start_mysql() {
  docker run -d --name "$DB_CONTAINER" --network "$NETWORK" \
    -e MYSQL_ROOT_PASSWORD="$ROOT_PASSWORD" \
    "$DB_IMAGE" >/dev/null
  wait_for MySQL mysql_value 'SELECT 1'
}

seed_mysql() {
  mysql_root <<SQL
CREATE DATABASE app;
USE app;
CREATE TABLE items (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(50) NOT NULL, payload BLOB);
CREATE TABLE audit (item_id INT NOT NULL);
INSERT INTO items (name, payload) VALUES ('alpha', 0x00FF10), ('beta', NULL);
CREATE VIEW item_names AS SELECT name FROM items;
CREATE TRIGGER items_after_insert AFTER INSERT ON items FOR EACH ROW INSERT INTO audit VALUES (NEW.id);
CREATE PROCEDURE count_items() SELECT COUNT(*) FROM items;
CREATE EVENT daily_noop ON SCHEDULE EVERY 1 DAY DO SELECT 1;
CREATE DATABASE analytics;
CREATE TABLE analytics.metrics (id INT PRIMARY KEY);
CREATE USER 'backup'@'%' IDENTIFIED BY '$MYSQL_BACKUP_PASSWORD';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, SHOW_ROUTINE ON *.* TO 'backup'@'%';
SQL
}

verify_mysql_restore() {
  local prefix="$1"

  mysql_value 'DROP DATABASE app'
  s3_volume cat "/fake-s3/$prefix/app/$TIMESTAMP.sql.gz" | gzip -dc | mysql_root

  assert_equal "row count" "$(mysql_value 'SELECT COUNT(*) FROM app.items')" 2
  assert_equal "blob payload" "$(mysql_value "SELECT HEX(payload) FROM app.items WHERE name = 'alpha'")" 00FF10
  assert_equal "view" "$(mysql_value "SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA = 'app'")" 1
  assert_equal "trigger" "$(mysql_value "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = 'app'")" 1
  assert_equal "routine" "$(mysql_value "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = 'app'")" 1
  assert_equal "event" "$(mysql_value "SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA = 'app'")" 1
  mysql_value "INSERT INTO app.items (name) VALUES ('gamma')"
  assert_equal "trigger works" "$(mysql_value 'SELECT COUNT(*) FROM app.audit')" 1
}

postgres_root() {
  docker exec -i "$DB_CONTAINER" \
    psql --no-psqlrc --set=ON_ERROR_STOP=1 --username=postgres "$@"
}

postgres_value() {
  postgres_root --tuples-only --no-align --dbname="${2:-postgres}" --command="$1"
}

postgres_tcp_ready() {
  docker exec -e PGPASSWORD="$ROOT_PASSWORD" "$DB_CONTAINER" \
    psql --host=127.0.0.1 --username=postgres --command='SELECT 1'
}

start_postgres() {
  docker run -d --name "$DB_CONTAINER" --network "$NETWORK" \
    -e POSTGRES_PASSWORD="$ROOT_PASSWORD" \
    "$DB_IMAGE" >/dev/null
  wait_for PostgreSQL postgres_tcp_ready
}

seed_postgres() {
  postgres_root --dbname=postgres <<SQL
CREATE ROLE app_owner NOLOGIN;
CREATE DATABASE app OWNER app_owner;
CREATE DATABASE analytics;
CREATE ROLE backup LOGIN PASSWORD '$BACKUP_PASSWORD';
GRANT pg_read_all_data TO backup;
SQL
  postgres_root --dbname=app <<'SQL'
SET ROLE app_owner;
CREATE TABLE items (id SERIAL PRIMARY KEY, name TEXT NOT NULL, payload BYTEA);
CREATE TABLE audit (item_id INT NOT NULL);
INSERT INTO items (name, payload) VALUES ('alpha', '\x00ff10'), ('beta', NULL);
CREATE VIEW item_names AS SELECT name FROM items;
CREATE FUNCTION log_item() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO audit VALUES (NEW.id);
  RETURN NEW;
END
$$;
CREATE TRIGGER items_after_insert AFTER INSERT ON items FOR EACH ROW EXECUTE FUNCTION log_item();
SQL
  postgres_value 'CREATE TABLE metrics (id INT PRIMARY KEY)' analytics
}

verify_postgres_restore() {
  local prefix="$1"
  local globals

  globals="$(s3_volume cat "/fake-s3/$prefix/_globals/$TIMESTAMP.sql.gz" | gzip -dc)"
  grep -q 'CREATE ROLE app_owner' <<< "$globals" || fail_test "globals missing app_owner"
  if grep -qi 'PASSWORD' <<< "$globals"; then
    fail_test "globals should not contain role passwords"
  fi

  postgres_value 'DROP DATABASE app'
  s3_volume cat "/fake-s3/$prefix/app/$TIMESTAMP.dump" \
    | docker exec -i "$DB_CONTAINER" \
      pg_restore --username=postgres --create --exit-on-error --dbname=postgres

  assert_equal "owner" "$(postgres_value "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'app'")" app_owner
  assert_equal "row count" "$(postgres_value 'SELECT COUNT(*) FROM items' app)" 2
  assert_equal "bytea payload" "$(postgres_value "SELECT encode(payload, 'hex') FROM items WHERE name = 'alpha'" app)" 00ff10
  assert_equal "view" "$(postgres_value 'SELECT COUNT(*) FROM item_names' app)" 2
  postgres_value "INSERT INTO items (name) VALUES ('gamma')" app
  assert_equal "sequence" "$(postgres_value "SELECT id FROM items WHERE name = 'gamma'" app)" 3
  assert_equal "trigger works" "$(postgres_value 'SELECT COUNT(*) FROM audit' app)" 1
}

if [[ "${SKIP_BUILD:-false}" != "true" ]]; then
  log "Building $IMAGE"
  docker build --target "$ENGINE" -t "$IMAGE" "$PROJECT_ROOT"
fi

log "Starting $DB_IMAGE"
docker network create "$NETWORK" >/dev/null
docker volume create "$S3_VOLUME" >/dev/null
"start_$ENGINE"

log "Seeding databases"
"seed_$ENGINE"

log "Running one-off backup"
mapfile -t BACKUP_ENV < <(backup_env)
docker run --rm "${BACKUP_ENV[@]}" \
  -e S3_PREFIX=manual \
  -e BACKUP_TIMESTAMP="$TIMESTAMP" \
  --entrypoint backup.sh \
  "$IMAGE"

objects="$(s3_volume find /fake-s3 -type f)"
grep -qx "/fake-s3/manual/app/$TIMESTAMP.$EXTENSION" <<< "$objects" || fail_test "app backup missing: $objects"
grep -qx "/fake-s3/manual/analytics/$TIMESTAMP.$EXTENSION" <<< "$objects" || fail_test "analytics backup missing: $objects"

log "Restoring app backup"
"verify_${ENGINE}_restore" manual

log "Running scheduled backup through crond"
docker run -d --name "$SCHEDULER_CONTAINER" "${BACKUP_ENV[@]}" \
  -e S3_PREFIX=scheduled \
  -e BACKUP_CRON='* * * * *' \
  "$IMAGE" >/dev/null

scheduled_backup_done() {
  docker logs "$SCHEDULER_CONTAINER" 2>&1 | grep 'Backup completed successfully' >/dev/null
}
wait_for "scheduled backup" scheduled_backup_done

objects="$(s3_volume find /fake-s3/scheduled -type f)"
grep -q "/app/[0-9]\{14\}\.${EXTENSION//./\\.}\$" <<< "$objects" || fail_test "scheduled backup missing: $objects"
docker exec "$SCHEDULER_CONTAINER" /opt/db-backup/healthcheck.sh || fail_test "container should be healthy"

started="$(date +%s)"
docker stop "$SCHEDULER_CONTAINER" >/dev/null
(( $(date +%s) - started < 8 )) || fail_test "container did not stop promptly"

printf '%s integration tests passed\n' "$ENGINE"
