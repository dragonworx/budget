#!/usr/bin/env bash
# Keeps ngrok up: restarts it within ~1s whenever it exits. Log is appended (rotated at 5 MB).
LOG=/workspace/dev-logs/tunnel.log
while true; do
  [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 5000000 ] && mv -f "$LOG" "$LOG.1"
  echo "t=$(date +%FT%T%z) lvl=info msg=\"tunnel-run: starting ngrok\"" >> "$LOG"
  ngrok http 127.0.0.1:8000 --log=stdout >> "$LOG" 2>&1
  echo "t=$(date +%FT%T%z) lvl=warn msg=\"tunnel-run: ngrok exited ($?), restarting\"" >> "$LOG"
  sleep 1
done
