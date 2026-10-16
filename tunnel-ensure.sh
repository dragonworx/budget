#!/usr/bin/env bash
# Shared ngrok ensure step (used by web-watch.sh after each live build, ./dev.sh tunnel, and the watchdog).
#   tunnel-ensure.sh          one public /health check (10s); if not 200, restart ngrok and wait <=15s for 200.
#                             Prints "tunnel OK" / "tunnel RESTORED in Ns" / "tunnel DOWN ..."; exit 0 iff public 200.
#   tunnel-ensure.sh restart  just restart ngrok (single ngrok: kill it, the tunnel-run.sh wrapper relaunches;
#                             recreate the budget:tunnel window if the wrapper is missing). Prints what it did.
ROOT="$(cd "$(dirname "$0")" && pwd)"; S=budget; LOGS=/workspace/dev-logs
PUBLIC=${PUBLIC_URL:-https://unsaid-generic-jubilance.ngrok-free.dev}
log() { echo "$(date '+%F %T %Z') $*" >> $LOGS/watchdog.log; }
public() { local c; c=$(curl -s -o /dev/null -m "${1:-10}" -H 'ngrok-skip-browser-warning: 1' -w '%{http_code}' "$PUBLIC/health"); echo "${c:-000}"; }
restart() {
  pkill -x ngrok; pkill -CONT -x ngrok   # CONT: a stopped ngrok must still exit
  if tmux list-windows -t $S -F '#W' 2>/dev/null | grep -qx tunnel && pgrep -f tunnel-run.sh >/dev/null; then
    echo "ngrok killed; wrapper relaunches"
  else
    tmux kill-window -t $S:tunnel 2>/dev/null; tmux new-window -d -t $S -n tunnel "$ROOT/tunnel-run.sh"; echo "tunnel window recreated"
  fi
}
[ "${1:-}" = restart ] && { restart; exit 0; }
src=${ENSURE_SRC:-manual}
c=$(public 10)
if [ "$c" = 200 ]; then echo "tunnel OK"; log "ensure($src): public 200, tunnel OK"; exit 0; fi
log "ensure($src): public /health -> $c; $(restart)"
t0=$SECONDS; sleep 3
while (( SECONDS - t0 < 15 )); do
  c=$(public 5); [ "$c" = 200 ] && { echo "tunnel RESTORED in $((SECONDS - t0))s"; log "ensure($src): tunnel RESTORED in $((SECONDS - t0))s"; exit 0; }
  sleep 2
done
echo "tunnel DOWN (public $c) — watchdog will keep retrying"; log "ensure($src): tunnel still DOWN after 15s (public $c)"; exit 1
