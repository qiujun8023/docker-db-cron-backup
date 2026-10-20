# shellcheck shell=bash disable=SC2034,SC2154
# MySQL engine for backup.sh.
# Sourced by backup.sh, which defines the shared helpers and DB_* settings.

ENGINE_DEFAULT_PORT=3306
ENGINE_EXTENSION=sql.gz

engine_require_commands() {
  require_command mysql
  require_command mysqldump
}

engine_configure() {
  local ssl_mode
  case "$DB_SSL_MODE" in
    disabled) ssl_mode=DISABLED ;;
    preferred) ssl_mode=PREFERRED ;;
    required) ssl_mode=REQUIRED ;;
    verify-ca) ssl_mode=VERIFY_CA ;;
    verify-full) ssl_mode=VERIFY_IDENTITY ;;
  esac

  export MYSQL_PWD="$DB_PASSWORD"
  MYSQL_CONNECTION_ARGS=(
    --host="$DB_HOST"
    --port="$DB_PORT"
    --user="$DB_USER"
    --protocol=TCP
    --ssl-mode="$ssl_mode"
  )
}

engine_is_system_database() {
  case "$1" in
    information_schema|mysql|performance_schema|sys) return 0 ;;
    *) return 1 ;;
  esac
}

engine_list_databases() {
  mysql "${MYSQL_CONNECTION_ARGS[@]}" --batch --skip-column-names \
    --execute="SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys') ORDER BY SCHEMA_NAME"
}

engine_dump() {
  local database="$1"
  local output="$2"

  mysqldump \
    "${MYSQL_CONNECTION_ARGS[@]}" \
    --single-transaction \
    --quick \
    --routines \
    --events \
    --triggers \
    --hex-blob \
    --no-tablespaces \
    --set-gtid-purged=OFF \
    --databases "$database" \
    | gzip "-$COMPRESSION_LEVEL" -n > "$output" \
    && gzip -t "$output"
}
