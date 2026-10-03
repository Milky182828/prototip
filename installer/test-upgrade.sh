#!/bin/sh
# Fault-injection tests of the real host updater. Run ONLY inside a disposable Linux
# container; Docker is replaced by a recording stand-in, no real daemon is contacted.
set -eu
[ "${PROTOTIP_INSTALLER_TEST:-}" = 1 ] || { echo 'Set PROTOTIP_INSTALLER_TEST=1 inside a disposable container' >&2; exit 1; }
[ ! -e /opt/prototip ] || { echo '/opt/prototip already exists; refusing to touch it' >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "Run as root: the updater takes its lock in /run" >&2; exit 1; }
bin=$(realpath "${1:-target/debug/prototip}")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp" /opt/prototip' EXIT INT TERM
mkdir -p "$tmp/bin"
export TEST_STATE="$tmp"
export PATH="$tmp/bin:$PATH"
# The stand-in knows every command the updater may run and fails on any other, so a
# wrong argument is caught even where the updater ignores the result (`unexpected`).
cat >"$tmp/bin/docker" <<'DOCKER'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$TEST_STATE/trace"
unexpected() {
  echo "fake docker: unexpected command: docker $*" >&2
  printf '%s\n' "$*" >>"$TEST_STATE/unexpected"
  exit 99
}
case "$1" in
  pull)
    [ $# = 2 ] || unexpected "$@"
    case "$2" in new-image | postgres:18-alpine@sha256:*) exit 0 ;; *) unexpected "$@" ;; esac ;;
  run)
    # setup::image_version: the sandboxed `IMAGE version`, answered per image
    last='' image=''
    for a in "$@"; do image=$last; last=$a; done
    [ "$last" = version ] || unexpected "$@"
    case "$image" in new-image) echo 0.5.0.1 ;; *) unexpected "$@" ;; esac
    exit 0 ;;
  image)
    # the database's image is never there yet: the update pulls it
    case "$*" in 'image inspect postgres:18-alpine@sha256:'*) exit 1 ;; *) unexpected "$@" ;; esac ;;
  volume)
    case "$*" in 'volume inspect --format {{.Mountpoint}} prototip_pg-data') exit 1 ;; *) unexpected "$@" ;; esac ;;
  rm)
    case "$*" in 'rm -f prototip-database-'*) exit 0 ;; *) unexpected "$@" ;; esac ;;
  compose) ;;
  *) unexpected "$@" ;;
esac
[ "$2 $3" = '--project-directory /opt/prototip' ] || unexpected "$@"
shift 3
new() { grep -q "^PROTOTIP_IMAGE=new-image" /opt/prototip/.env; }
db='run --rm --no-deps -T --name prototip-database-'
case "$*" in
  'exec -T panel prototip admin backup /data/panel/backup.db')
    cp /opt/prototip/data/panel/prototip.db /opt/prototip/data/panel/backup.db ;;
  "$db"*' panel database backup /data/panel/backup.dump')
    [ ! -f "$TEST_STATE/dump-fail" ] || { echo 'pg_dump: relation is corrupt' >&2; exit 1; }
    cp "$TEST_STATE/pg" /opt/prototip/data/panel/backup.dump ;;
  "$db"*' panel database migrate')
    [ -f "$TEST_STATE/pg" ] || echo 'imported users, payment42' >"$TEST_STATE/pg"
    [ ! -f "$TEST_STATE/migrate-fail" ] || { echo 'lost response after commit' >&2; exit 1; }
    echo "PostgreSQL schema version: $(cat "$TEST_STATE/schema" 2>/dev/null || echo "1 -> 1")" ;;
  "$db"*' panel database restore /data/panel/restore.dump')
    [ ! -f "$TEST_STATE/restore-fail" ] || { echo 'pg_restore failed' >&2; exit 1; }
    cp /opt/prototip/data/panel/restore.dump "$TEST_STATE/pg" ;;
  'up -d --wait --wait-timeout 120 postgres')
    [ ! -f "$TEST_STATE/pg-fail" ] || { echo 'database startup failed' >&2; exit 1; }
    if [ -f "$TEST_STATE/pg-fail-new" ] && new; then echo "database startup failed" >&2; exit 1; fi ;;
  'up -d')
    [ ! -f "$TEST_STATE/start-fail" ] || { echo 'panel startup failed' >&2; exit 1; }
    if [ -f "$TEST_STATE/start-fail-new" ] && new; then echo "new panel startup failed" >&2; exit 1; fi
    if [ -f "$TEST_STATE/start-fail-old" ] && ! new; then echo "old panel refuses the schema" >&2; exit 1; fi
    touch "$TEST_STATE/healthy" ;;
  'up -d panel') touch "$TEST_STATE/healthy" ;;
  'exec -T panel prototip health')
    [ -f "$TEST_STATE/healthy" ] ;;
  'stop panel' | 'stop') rm -f "$TEST_STATE/healthy" ;;
  'stop postgres') ;;
  'logs --tail 30') echo 'panel: last log line' ;;
  *) unexpected compose "$@" ;;
esac
DOCKER
chmod +x "$tmp/bin/docker"

# Every scenario ends with no command the stand-in did not know.
strict() {
  if [ -e "$tmp/unexpected" ]; then
    echo 'the updater ran docker commands nobody expected:' >&2
    cat "$tmp/unexpected" >&2
    exit 1
  fi
}

fixture() {
  strict
  rm -rf /opt/prototip
  mkdir -p /opt/prototip/data/panel /opt/prototip/data/node
  printf 'PROTOTIP_IMAGE=old-image\nPROTOTIP_VERSION=0.4.4\nPANEL_PORT=21355\n' >/opt/prototip/.env
  printf 'legacy compose\n' >/opt/prototip/compose.yaml
  printf 'original users, payment42\n' >/opt/prototip/data/panel/prototip.db
  printf 'last WAL transaction\n' >/opt/prototip/data/panel/prototip.db-wal
  rm -f "$tmp/pg" "$tmp/trace" "$tmp/healthy" "$tmp/start-fail" "$tmp/pg-fail" "$tmp/migrate-fail" \
    "$tmp/schema" "$tmp/pg-fail-new" "$tmp/start-fail-new" "$tmp/start-fail-old" "$tmp/dump-fail" "$tmp/restore-fail"
}

# A server already on PostgreSQL (0.5.0.0 and later).
pg_fixture() {
  fixture
  rm -f /opt/prototip/data/panel/prototip.db /opt/prototip/data/panel/prototip.db-wal
  printf 'PROTOTIP_IMAGE=old-image\nPROTOTIP_VERSION=0.5.0.0\nPANEL_PORT=21355\nPROTOTIP_POSTGRES_PASSWORD=livepassword\nPROTOTIP_DATABASE_URL=postgresql://prototip:livepassword@localhost/prototip?host=/run/postgresql\n' >/opt/prototip/.env
  echo 'live users, payment77' >"$tmp/pg"
}

# The line of the first trace entry that contains $1.
at() { grep -n -- "$1" "$tmp/trace" | head -1 | cut -d: -f1; }
last() { grep -n -- "$1" "$tmp/trace" | tail -1 | cut -d: -f1; }

fixture
touch "$tmp/pg-fail"
if "$bin" update new-image >"$tmp/output" 2>&1; then echo 'startup fault must fail' >&2; exit 1; fi
grep -q 'could not prepare the database' "$tmp/output"
grep -q 'runs again' "$tmp/output"
grep -q 'PROTOTIP_IMAGE=old-image' /opt/prototip/.env
grep -q 'legacy compose' /opt/prototip/compose.yaml
grep -q 'original users' /opt/prototip/data/panel/prototip.db
grep -q 'stop postgres' "$tmp/trace"
[ -e "$tmp/healthy" ]
# The database volume may already be initialized with this password: it must survive.
password=$(grep '^PROTOTIP_POSTGRES_PASSWORD=' /opt/prototip/.env)
[ -n "$password" ]
if grep -q 'PROTOTIP_DATABASE_URL=' /opt/prototip/.env; then echo 'unexpected: PROTOTIP_DATABASE_URL=' >&2; exit 1; fi
rm "$tmp/pg-fail" "$tmp/trace"
"$bin" update new-image >"$tmp/output" 2>&1
grep -qx "$password" /opt/prototip/.env
grep -q "PROTOTIP_DATABASE_URL=postgresql://prototip:${password#PROTOTIP_POSTGRES_PASSWORD=}@" /opt/prototip/.env
[ -e "$tmp/healthy" ]
# The database's image is pulled before the backup and the stop, not by `compose up`.
pull=$(at 'pull postgres:18-alpine@sha256:')
[ -n "$pull" ] && [ "$pull" -lt "$(at 'admin backup')" ] && [ "$pull" -lt "$(at 'stop panel')" ]
# One archive per attempt, of the move's own kind: the stopped SQLite with its WAL.
[ "$(ls /opt/prototip/backups | grep -c '^pre-postgres-')" = 2 ]
for f in /opt/prototip/backups/pre-postgres-*; do tar -tzf "$f" | grep -qx 'data/panel/prototip.db-wal'; done

# PostgreSQL to PostgreSQL: a database that cannot start brings the previous version back.
pg_fixture
touch "$tmp/pg-fail-new"
if "$bin" update new-image >"$tmp/output" 2>&1; then echo 'database fault must fail' >&2; exit 1; fi
grep -q 'could not prepare the database' "$tmp/output"
grep -q 'PROTOTIP_IMAGE=old-image' /opt/prototip/.env
grep -q 'PROTOTIP_POSTGRES_PASSWORD=livepassword' /opt/prototip/.env
[ -e "$tmp/healthy" ]
if grep -q 'stop postgres' "$tmp/trace"; then echo 'unexpected: stop postgres' >&2; exit 1; fi

# A migration that fails on PostgreSQL goes back to the previous version, compose and all.
pg_fixture
touch "$tmp/migrate-fail"
if "$bin" update new-image >"$tmp/output" 2>&1; then echo 'migration fault must fail' >&2; exit 1; fi
grep -q 'could not migrate the database' "$tmp/output"
grep -q 'runs again' "$tmp/output"
grep -q 'PROTOTIP_IMAGE=old-image' /opt/prototip/.env
grep -q 'PROTOTIP_POSTGRES_PASSWORD=livepassword' /opt/prototip/.env
grep -q 'legacy compose' /opt/prototip/compose.yaml
[ -e "$tmp/healthy" ]
# The final dump is taken with the panel stopped; the one before it was only the gate.
[ "$(at 'stop panel')" -lt "$(last 'database backup')" ]
[ "$(at 'database backup')" -lt "$(at 'stop panel')" ]
[ "$(ls /opt/prototip/backups | grep -c '^pre-update-')" = 1 ]

# ...and when the previous version refuses what the migration left, the panel stays stopped.
pg_fixture
touch "$tmp/migrate-fail" "$tmp/start-fail-old"
if "$bin" update new-image >"$tmp/output" 2>&1; then echo 'migration fault must fail' >&2; exit 1; fi
grep -q 'does not start either' "$tmp/output"
grep -q 'the panel is stopped' "$tmp/output"
[ ! -e "$tmp/healthy" ]
[ "$(tail -1 "$tmp/trace")" = 'compose --project-directory /opt/prototip stop panel' ]

# An unchanged schema lets a release that does not start go back to the previous image.
pg_fixture
touch "$tmp/start-fail-new"
if "$bin" update new-image >"$tmp/output" 2>&1; then echo 'startup fault must fail' >&2; exit 1; fi
grep -q 'PROTOTIP_IMAGE=old-image' /opt/prototip/.env
grep -q 'PROTOTIP_DATABASE_URL=' /opt/prototip/.env
grep -q 'legacy compose' /opt/prototip/compose.yaml
[ -e "$tmp/healthy" ]
grep -q 'runs again' "$tmp/output"

# A schema the new release moved forward stays: the previous binary would refuse it.
pg_fixture
touch "$tmp/start-fail-new"
echo '1 -> 2' >"$tmp/schema"
if "$bin" update new-image >"$tmp/output" 2>&1; then echo 'startup fault must fail' >&2; exit 1; fi
grep -q 'PROTOTIP_IMAGE=new-image' /opt/prototip/.env
[ ! -e "$tmp/healthy" ]
grep -q 'No automatic database rollback is safe' "$tmp/output"

fixture
touch "$tmp/migrate-fail"
if "$bin" update new-image >"$tmp/output" 2>&1; then echo 'lost migration response must fail' >&2; exit 1; fi
grep -q 'PROTOTIP_IMAGE=new-image' /opt/prototip/.env
grep -q 'PROTOTIP_DATABASE_URL=' /opt/prototip/.env
[ ! -e "$tmp/healthy" ]
echo 'new post-import payment43' >>"$tmp/pg"
rm "$tmp/migrate-fail"
"$bin" update new-image >"$tmp/output" 2>&1
grep -q 'payment43' "$tmp/pg"
grep -q 'original users' /opt/prototip/data/panel/prototip.db
[ -e "$tmp/healthy" ]
# The retry is an update of PostgreSQL: the archive of the original SQLite stays apart.
ls /opt/prototip/backups | grep -q '^pre-postgres-'
ls /opt/prototip/backups | grep -q '^pre-update-'

fixture
touch "$tmp/start-fail"
if "$bin" update new-image >"$tmp/output" 2>&1; then echo 'panel startup fault must fail' >&2; exit 1; fi
grep -q 'PROTOTIP_IMAGE=new-image' /opt/prototip/.env
grep -q 'imported users' "$tmp/pg"
[ ! -e "$tmp/healthy" ]
grep -q 'No automatic database rollback is safe' "$tmp/output"
[ "$(at 'stop panel')" -lt "$(at 'panel database migrate')" ]

# A restore puts the dump into PostgreSQL and leaves no copy of it in data/panel.
pg_fixture
"$bin" backup >"$tmp/output" 2>&1
archive=$(ls /opt/prototip/backups/prototip-*.tar.gz)
echo 'changed after the backup' >"$tmp/pg"
"$bin" restore -y "$archive" >"$tmp/output" 2>&1
grep -q 'live users, payment77' "$tmp/pg"
[ ! -e /opt/prototip/data/panel/restore.dump ]
[ -e "$tmp/healthy" ]
tar -tzf /opt/prototip/backups/pre-restore-*.tar.gz | grep -qx 'data/panel/backup.dump'
# ...also when PostgreSQL does not take it.
touch "$tmp/restore-fail"
if "$bin" restore -y "$archive" >"$tmp/output" 2>&1; then echo 'restore fault must fail' >&2; exit 1; fi
grep -q 'prototip does not start' "$tmp/output"
[ ! -e /opt/prototip/data/panel/restore.dump ]
rm "$tmp/restore-fail"
# A database that cannot be dumped stops the restore, which names the way past it.
touch "$tmp/dump-fail"
if "$bin" restore -y "$archive" >"$tmp/output" 2>&1; then echo 'snapshot fault must fail' >&2; exit 1; fi
grep -q 'nothing was replaced' "$tmp/output"
grep -q -- "--no-db-snapshot $archive" "$tmp/output"
[ -e "$tmp/healthy" ]
"$bin" restore -y --no-db-snapshot "$archive" >"$tmp/output" 2>&1
grep -q 'NOT saved' "$tmp/output"
grep -q 'live users, payment77' "$tmp/pg"
[ ! -e /opt/prototip/data/panel/restore.dump ]

# A database-only archive (what the panel sends to Telegram, after age -d) puts the dump
# back and keeps the server's own files: .env, certificates, node data.
pg_fixture
env_before=$(sha256sum /opt/prototip/.env)
mkdir -p "$tmp/dbonly/data/panel"
echo 'telegram users, payment99' >"$tmp/dbonly/data/panel/backup.dump"
tar -czf "$tmp/dbonly.tar.gz" -C "$tmp/dbonly" data
"$bin" restore -y "$tmp/dbonly.tar.gz" >"$tmp/output" 2>&1
grep -q 'telegram users, payment99' "$tmp/pg"
grep -q "holds only the panel's database" "$tmp/output"
[ "$(sha256sum /opt/prototip/.env)" = "$env_before" ]
[ ! -e /opt/prototip/data/panel/restore.dump ]
[ -e "$tmp/healthy" ]
tar -tzf /opt/prototip/backups/pre-restore-*.tar.gz | grep -qx 'data/panel/backup.dump'

# A server that went back to SQLite restores an SQLite archive and keeps its compose file.
fixture
"$bin" backup >"$tmp/output" 2>&1
archive=$(ls /opt/prototip/backups/prototip-*.tar.gz)
printf 'PROTOTIP_IMAGE=old-image\nPROTOTIP_VERSION=0.4.4\nPANEL_PORT=21355\nPROTOTIP_POSTGRES_PASSWORD=kept\n' >/opt/prototip/.env
echo 'written after the backup' >/opt/prototip/data/panel/prototip.db
"$bin" restore -y "$archive" >"$tmp/output" 2>&1
grep -q 'original users' /opt/prototip/data/panel/prototip.db
grep -q 'legacy compose' /opt/prototip/compose.yaml
grep -q 'PROTOTIP_POSTGRES_PASSWORD=kept' /opt/prototip/.env
if grep -q 'database restore\|postgres' "$tmp/trace"; then echo 'unexpected: PostgreSQL on an SQLite restore' >&2; exit 1; fi
[ -e "$tmp/healthy" ]
strict
echo 'host updater: strict docker, provisioning rollback, kept database password, PostgreSQL image pulled first, final dump after the stop, PostgreSQL rollback on a failed migration and on an unchanged schema, uncertain commit retry, preserved post-import writes and SQLite archive, startup failure and writer-stop order, restore without a dump left behind, restore without a database snapshot, database-only restore, SQLite restore passed'
