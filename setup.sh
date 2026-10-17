#!/usr/bin/env bash
# Idempotent bootstrap for the budget dev env (safe to re-run while the stack is up).
#   ./setup.sh            install deps, repair/init Postgres, DBs + migrations, start stack, verify
#   ./setup.sh --deps     only install/repair system deps + data dir (used by `dev.sh start`)
#   ./setup.sh --check    report what is missing, change nothing
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"; LOGS=/workspace/dev-logs; PGDATA=/workspace/dev-data/pg
PGVER=17; PGBIN=/usr/lib/postgresql/$PGVER/bin; NGROK_CFG="$HOME/.config/ngrok/ngrok.yml"
PUBLIC_URL=https://unsaid-generic-jubilance.ngrok-free.dev
MODE=${1:-full}; FAIL=0
say() { echo "[setup] $*"; }; warn() { echo "[setup] WARN: $*" >&2; FAIL=1; }
export PATH="$HOME/flutter/bin:$PATH" DEBIAN_FRONTEND=noninteractive
APT_UPDATED=0; apt_install() { [ $APT_UPDATED = 1 ] || { sudo apt-get update -qq; APT_UPDATED=1; }; sudo apt-get install -y -qq "$@" >/dev/null; }
check_only() { [ "$MODE" = --check ]; }

# 1. apt deps
missing=(); for c in tmux:tmux inotifywait:inotify-tools curl:curl node:nodejs; do command -v ${c%%:*} >/dev/null || missing+=(${c#*:}); done
if [ ${#missing[@]} -gt 0 ]; then check_only && warn "missing apt pkgs: ${missing[*]}" || { say "installing ${missing[*]}"; apt_install "${missing[@]}"; }; else say "apt deps ok"; fi

# 2. Postgres 17 (data dir is PG_VERSION $PGVER)
if [ ! -x "$PGBIN/postgres" ]; then
  if check_only; then warn "postgres $PGVER missing"; else
    say "installing postgresql-$PGVER (PGDG)"
    apt_install postgresql-common ca-certificates
    sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y >/dev/null 2>&1; APT_UPDATED=0
    apt_install postgresql-$PGVER
  fi
else say "postgres $PGVER ok"; fi
# never let the distro cluster grab :5432
if [ -d /etc/postgresql ] && ! check_only; then
  sudo systemctl disable --now postgresql >/dev/null 2>&1 || true
  sudo service postgresql stop >/dev/null 2>&1 || true
  for f in /etc/postgresql/*/*/start.conf; do [ -f "$f" ] && echo manual | sudo tee "$f" >/dev/null; done
fi

# 3. ngrok
if ! command -v ngrok >/dev/null; then
  check_only && warn "ngrok missing" || { say "installing ngrok"; curl -sL https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz | sudo tar xz -C /usr/local/bin; }
else say "ngrok ok"; fi
if [ -f "$NGROK_CFG" ] && grep -q '^ *authtoken:' "$NGROK_CFG"; then say "ngrok config ok (token present)"
elif [ -f "$NGROK_CFG.bak" ] && grep -q '^ *authtoken:' "$NGROK_CFG.bak" && ! check_only; then cp "$NGROK_CFG.bak" "$NGROK_CFG"; say "ngrok config restored from .bak"
else warn "ngrok authtoken missing: run  ngrok config add-authtoken <TOKEN>  (dashboard.ngrok.com/get-started/your-authtoken)"; fi

# 4. Flutter
if [ -x "$HOME/flutter/bin/flutter" ]; then say "flutter ok"; else
  warn "Flutter not found in ~/flutter. Install: git clone https://github.com/flutter/flutter.git -b stable ~/flutter && ~/flutter/bin/flutter precache --web"; fi

# 5. data dir repair / init
mkdir -p "$LOGS"
if [ -f "$PGDATA/PG_VERSION" ]; then
  v=$(cat "$PGDATA/PG_VERSION"); [ "$v" = "$PGVER" ] || warn "data dir is PG $v, expected $PGVER"
  if ! check_only; then
    chmod 700 "$PGDATA"
    for d in pg_notify pg_serial pg_snapshots pg_replslot pg_tblspc pg_twophase pg_commit_ts pg_dynshmem pg_stat pg_stat_tmp \
             pg_logical/snapshots pg_logical/mappings pg_wal/archive_status pg_wal/summaries pg_subtrans pg_multixact/members pg_multixact/offsets pg_xact; do
      mkdir -p "$PGDATA/$d"; done
    chmod -R go-rwx "$PGDATA"; say "data dir repaired/ok"
  fi
elif ! check_only && [ -x "$PGBIN/initdb" ]; then
  say "initialising new (empty) data dir"; mkdir -p "$PGDATA"; chmod 700 "$PGDATA"
  "$PGBIN/initdb" -D "$PGDATA" -U budget --auth=trust >/dev/null
else warn "no data dir at $PGDATA"; fi

check_only && { [ $FAIL = 0 ] && say "all good" || say "issues found"; exit $FAIL; }
[ "$MODE" = --deps ] && exit 0

# 6. Postgres up, DBs, migrations
"$PGBIN/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1 || { rm -f "$PGDATA/postmaster.pid"; "$PGBIN/pg_ctl" -D "$PGDATA" -l $LOGS/postgres.log -o "-k /tmp -h 127.0.0.1" -w start >/dev/null || { warn "postgres failed, see $LOGS/postgres.log"; exit 1; }; }
for db in budget budget_test; do
  "$PGBIN/psql" -h 127.0.0.1 -U budget -d postgres -tAc "select 1 from pg_database where datname='$db'" | grep -q 1 || { say "creating DB $db"; "$PGBIN/createdb" -h 127.0.0.1 -U budget $db; }
  (cd "$ROOT/server" && dart pub get >/dev/null && DATABASE_URL=postgres://budget:budget@127.0.0.1:5432/$db dart run bin/migrate.dart) >>$LOGS/migrate.log 2>&1 && say "migrations ok ($db)" || warn "migrations failed for $db (see $LOGS/migrate.log)"
done

# 7. start stack (no-op if running) + verify
"$ROOT/dev.sh" start >/dev/null 2>&1; tmux has-session -t budget 2>/dev/null && say "tmux session 'budget' up" || warn "stack not running"
for i in $(seq 1 90); do grep -q 'live in' $LOGS/flutter.log 2>/dev/null && break; sleep 2; done
c=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/); [ "$c" = 200 ] && say "proxy :8000 -> 200" || warn "proxy :8000 -> $c"
c=$(curl -s -o /dev/null -w '%{http_code}' -H 'ngrok-skip-browser-warning: 1' $PUBLIC_URL/health); [ "$c" = 200 ] && say "tunnel $PUBLIC_URL -> 200" || warn "tunnel -> $c (try ./dev.sh tunnel)"
say "flutter: $(grep 'live in' $LOGS/flutter.log | tail -1)"
exit $FAIL
