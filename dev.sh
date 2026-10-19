#!/usr/bin/env bash
# Dev env: Postgres + Dart API (auto-restart) + Flutter web + proxy (:8000) + ngrok tunnel, all in tmux session "budget".
# Usage: ./dev.sh start|stop|status|reload|restart|url|logs|watchdog
# The watchdog window (tunnel-watchdog.sh) auto-restarts ngrok / proxy / API; log: /workspace/dev-logs/watchdog.log
#
# Web modes (WEB_MODE env, default "release"):
#   release  web-watch.sh builds `flutter build web --release` and rebuilds on any change under
#            client/lib, client/web or pubspec.yaml (~40s); the proxy serves that build statically.
#            ~10 requests per page load, so it loads quickly and reliably through ngrok.
#            After a change: wait for "live" in the web window (or ./dev.sh logs), then reload the browser.
#   debug    `flutter run -d web-server` (DDC, ~600 module requests per load, hot reload via r/R).
#            Fine on 127.0.0.1:8000 but too heavy for ngrok free (slow, burns the request quota).
#            Start with: WEB_MODE=debug ./dev.sh restart
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"; LOGS=/workspace/dev-logs; PGDATA=/workspace/dev-data/pg
PGBIN=$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)
[ -f "$ROOT/.env" ] || { [ -f "$ROOT/.env.example" ] && sed "s/^SESSION_SECRET=$/SESSION_SECRET=$(openssl rand -hex 32)/" "$ROOT/.env.example" > "$ROOT/.env" && echo "created .env from .env.example (AUTH_DEV_BYPASS=true)"; }
# Auth/app settings come from $ROOT/.env (read by the server itself); DB/host below override it.
export PATH="$HOME/flutter/bin:$PATH" DATABASE_URL=postgres://budget:budget@127.0.0.1:5432/budget API_HOST=127.0.0.1 API_PORT=8080
WEB_PORT=5080; PROXY_PORT=8000; S=budget; WEB_MODE=${WEB_MODE:-release}; export WEB_MODE
pg_start() {
  if [ ! -d "$PGDATA" ]; then mkdir -p "$PGDATA"; "$PGBIN/initdb" -D "$PGDATA" -U budget --auth=trust >/dev/null; fi
  "$PGBIN/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1 || "$PGBIN/pg_ctl" -D "$PGDATA" -l $LOGS/postgres.log -o "-k /tmp -h 127.0.0.1" start >/dev/null
  "$PGBIN/psql" -h 127.0.0.1 -U budget -d postgres -tAc "select 1 from pg_database where datname='budget'" | grep -q 1 || "$PGBIN/createdb" -h 127.0.0.1 -U budget budget
}
case "${1:-}" in
setup) exec "$ROOT/setup.sh" "${@:2}" ;;
start)
  if [ ! -x "$PGBIN/postgres" ] || ! command -v ngrok >/dev/null || ! command -v inotifywait >/dev/null; then
    echo "missing system deps -> running setup.sh --deps"; "$ROOT/setup.sh" --deps || exit 1
    PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
  fi
  mkdir -p $LOGS; pg_start
  (cd "$ROOT/server" && dart pub get >/dev/null && dart run bin/migrate.dart) 2>&1 | tee $LOGS/migrate.log
  tmux has-session -t $S 2>/dev/null && { echo "already running"; exit 0; }
  tmux new-session -d -s $S -n api "cd $ROOT/server && while true; do dart run bin/server.dart & P=\$!; inotifywait -qq -r -e modify,create,delete,move lib bin; echo '--- change detected, restarting API'; kill \$P; wait \$P 2>/dev/null; done 2>&1 | tee $LOGS/api.log"
  if [ "$WEB_MODE" = debug ]; then
    tmux new-window -t $S -n web "cd $ROOT/client && flutter run -d web-server --web-port=$WEB_PORT --web-hostname=0.0.0.0 --no-dds --dart-define=API_BASE_URL= 2>&1 | tee $LOGS/flutter.log"
  else
    tmux new-window -t $S -n web "$ROOT/web-watch.sh 2>&1 | tee $LOGS/flutter.log"
  fi
  tmux new-window -t $S -n proxy "WEB_MODE=$WEB_MODE node $ROOT/dev-proxy.js 2>&1 | tee $LOGS/proxy.log"
  tmux new-window -t $S -n tunnel "$ROOT/tunnel-run.sh"   # restarts ngrok on exit
  tmux new-window -d -t $S -n watchdog "WEB_MODE=$WEB_MODE $ROOT/tunnel-watchdog.sh"
  for i in $(seq 1 30); do [ -n "$("$0" url)" ] && break; sleep 1; done
  "$0" url ;;
stop) tmux kill-session -t $S 2>/dev/null || true; "$PGBIN/pg_ctl" -D "$PGDATA" stop >/dev/null 2>&1 || true; echo stopped ;;
reload)   # debug: hot reload; release: force a rebuild now (changes rebuild automatically anyway)
  if tmux capture-pane -pt $S:web | grep -q 'Flutter run key commands\|hot restart\|Hot reload'; then tmux send-keys -t $S:web r
  else touch "$ROOT/client/build/.rebuild"; echo "rebuild triggered; watch: $0 logs"; fi ;;
restart)  # full restart of all processes (keeps Postgres + the same ngrok URL on this account)
  tmux kill-session -t $S 2>/dev/null || true; sleep 1; "$0" start ;;
logs) tail -n ${2:-15} $LOGS/flutter.log ;;
status) tmux list-windows -t $S 2>/dev/null || echo "not running"; "$PGBIN/pg_ctl" -D "$PGDATA" status | head -1
  echo "watchdog:"; tail -n 3 $LOGS/watchdog.log 2>/dev/null || echo "  (no log)" ;;
watchdog)  # (re)start just the watchdog window in a running session
  tmux kill-window -t $S:watchdog 2>/dev/null || true
  tmux new-window -d -t $S -n watchdog "WEB_MODE=$WEB_MODE $ROOT/tunnel-watchdog.sh"; echo "watchdog started" ;;
tunnel) ENSURE_SRC=manual "$ROOT/tunnel-ensure.sh" ;;   # check public /health; restart ngrok if down
url) curl -s 127.0.0.1:4040/api/tunnels 2>/dev/null | grep -o '"public_url":"https://[^"]*' | cut -d'"' -f4 | head -1 ;;
*) echo "usage: [WEB_MODE=debug] $0 start|stop|status|reload|restart|url|tunnel|logs|watchdog"; exit 1 ;;
esac
