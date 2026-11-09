#!/usr/bin/env bash
# Applies supabase/migrations to a throwaway local Postgres and runs supabase/tests.
# Needs Homebrew postgresql (any recent version). Does not touch any running server.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Without a valid locale, Postgres on macOS aborts with "postmaster became multithreaded".
export LC_ALL="${LC_ALL:-en_US.UTF-8}" LANG="${LANG:-en_US.UTF-8}"
PGBIN="${PGBIN:-}"
if [[ -z "$PGBIN" ]]; then
  for v in 18 17 16; do
    if [[ -x "$(brew --prefix "postgresql@$v" 2>/dev/null)/bin/initdb" ]]; then
      PGBIN="$(brew --prefix "postgresql@$v")/bin"; break
    fi
  done
fi
[[ -x "$PGBIN/initdb" ]] || { echo "initdb not found; brew install postgresql@18 or set PGBIN" >&2; exit 1; }

# Short path on purpose: Postgres Unix socket paths must be < 104 bytes,
# and $TMPDIR can be long on macOS.
TMP="$(mktemp -d /tmp/wsdb.XXXXXX)"
PORT="${TEST_DB_PORT:-54329}"
cleanup() {
  "$PGBIN/pg_ctl" -D "$TMP/data" stop -m immediate >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

"$PGBIN/initdb" -D "$TMP/data" -U postgres --auth=trust --no-instructions >/dev/null
"$PGBIN/pg_ctl" -D "$TMP/data" -l "$TMP/server.log" -w \
  -o "-p $PORT -k $TMP -c listen_addresses=''" start >/dev/null

psql_run() {
  "$PGBIN/psql" -h "$TMP" -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -q -X "$@"
}

psql_run -f "$ROOT/supabase/tests/auth_stub.sql"
for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "▶ migrate $(basename "$f")"
  psql_run -f "$f"
done
for f in "$ROOT"/supabase/tests/[0-9]*.sql; do
  echo "▶ test $(basename "$f")"
  psql_run -o /dev/null -f "$f"   # hide query result rows; errors and \echo still print
done
echo "All database tests passed."
