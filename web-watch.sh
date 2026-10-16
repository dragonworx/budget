#!/usr/bin/env bash
# Release build of the Flutter client, rebuilt on every change under client/lib, client/web or pubspec.yaml.
# Builds into build/web-<n> and atomically repoints build/web-live (what dev-proxy.js serves), so the
# old build keeps serving until the new one is complete. Touch client/build/.rebuild (./dev.sh reload) to force.
set -uo pipefail
cd "$(dirname "$0")/client"; export PATH="$HOME/flutter/bin:$PATH"
build() {
  local out="build/web-$(date +%s)" t0=$SECONDS
  echo "--- $(date +%T) building release -> $out"
  if flutter build web --release --pwa-strategy=none --dart-define=API_BASE_URL= -o "$out" 2>&1 | grep -v '^$' | tail -4 && [ -f "$out/main.dart.js" ]; then
    ln -sfn "$(basename "$out")" build/web-live.tmp && mv -T build/web-live.tmp build/web-live
    ls -d build/web-[0-9]* | sort | head -n -2 | xargs -r rm -rf   # keep current + previous
    local live=$((SECONDS - t0)) tun
    tun=$(ENSURE_SRC=build ../tunnel-ensure.sh | tail -1)   # one public request per build
    echo "--- $(date +%T) live in ${live}s — $tun — reload the browser"
  else echo "--- $(date +%T) BUILD FAILED; previous build still live"; fi
}
mkdir -p build; touch build/.rebuild; build
while inotifywait -qq -r -e modify,attrib,close_write,create,delete,move lib web pubspec.yaml build/.rebuild 2>/dev/null || inotifywait -qq -r -e modify,attrib,close_write,create,delete,move lib web pubspec.yaml; do
  sleep 1; build
done
