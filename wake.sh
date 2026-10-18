#!/usr/bin/env bash
# Fast wake: bring the dev stack + ngrok tunnel back as quickly as possible.
cd "$(dirname "$0")"
URL=https://unsaid-generic-jubilance.ngrok-free.dev/health
t0=$(date +%s)
need_setup=0
for b in ngrok inotifywait; do command -v $b >/dev/null || need_setup=1; done
ls /usr/lib/postgresql/17/bin/pg_ctl >/dev/null 2>&1 || need_setup=1
if [ $need_setup = 1 ]; then echo "tools missing -> setup"; ./setup.sh || exit 1
elif ! tmux has-session -t budget 2>/dev/null; then echo "stack down -> start"; ./dev.sh start >/dev/null 2>&1
else pkill -x ngrok; fi   # tunnel-run wrapper relaunches ngrok
pgrep -f tunnel-watchdog.sh >/dev/null || ./dev.sh watchdog >/dev/null
local_ok=$(curl -s -m 5 -o /dev/null -w "%{http_code}" http://127.0.0.1:8000/health)
for i in $(seq 1 30); do
  c=$(curl -s -m 5 -o /dev/null -w "%{http_code}" $URL)
  [ "$c" = 200 ] && { echo "WAKE OK in $(( $(date +%s)-t0 ))s (local $local_ok, public 200)"; exit 0; }
  sleep 1
done
echo "WAKE FAILED after $(( $(date +%s)-t0 ))s (local $local_ok, public $c)"; curl -s -m 5 $URL | grep -oE 'ERR_NGROK_[0-9]+' | head -1; exit 1
