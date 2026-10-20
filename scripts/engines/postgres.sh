# shellcheck shell=bash disable=SC2034,SC2154
# PostgreSQL engine for backup.sh.
# Sourced by backup.sh, which defines the shared helpers and DB_* settings.

ENGINE_DEFAULT_PORT=5432
ENGINE_EXTENSION=dump

engine_require_commands() {
  require_command psql
  require_command pg_dump
  require_command pg_dumpall
  require_command pg_restore
}

engine_configure() {
  case "$DB_SSL_MODE" in
    disabled) PGSSLMODE=disable ;;
    preferred) PGSSLMODE=prefer ;;
    required) PGSSLMODE=require ;;
    verify-ca|verify-full) PGSSLMODE="$DB_SSL_MODE" ;;
  esac

  export PGHOST="$DB_HOST"
  export PGPORT="$DB_PORT"
  export PGUSER="$DB_USER"
  export PGPASSWORD="$DB_PASSWORD"
  export PGSSLMODE
  export PGDATABASE=postgres
  export PGAPPNAME=db-backup
}

engine_is_system_database() {
  case "$1" in
    template0|template1) return 0 ;;
    *) return 1 ;;
  esac
}

engine_list_databases() {
  psql --no-psqlrc --tuples-only --no-align --set=ON_ERROR_STOP=1 \
    --command="SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate AND datname <> 'postgres' ORDER BY datname"
}

# Roles and tablespaces live outside any database; role passwords are left
# out so a non-superuser account can read them.
engine_dump_globals() {
  local output="$1"

  pg_dumpall --globals-only --no-role-passwords \
    | gzip "-$COMPRESSION_LEVEL" -n > "$output" \
    && gzip -t "$output"
}

# Custom format keeps per-object restore and parallel pg_restore. Reading the
# whole archive back through pg_restore checks every data block.
engine_dump() {
  local database="$1"
  local output="$2"

  pg_dump --format=custom --compress="$COMPRESSION_LEVEL" \
    --dbname="$database" --file="$output" \
    && pg_restore --file=/dev/null "$output"
}
