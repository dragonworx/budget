# Budget web client baked into a Caddy image (static files + reverse proxy).
# Build context: repo root  (docker build -f client/Dockerfile .)
# Flutter is installed from its git tag so the image matches the client's SDK
# constraint (prebuilt Flutter images lag behind stable releases).
FROM debian:bookworm-slim AS build
ARG FLUTTER_VERSION=3.47.7
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils brotli zstd \
 && rm -rf /var/lib/apt/lists/* \
 && git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git /opt/flutter
ENV PATH=/opt/flutter/bin:$PATH FLUTTER_SUPPRESS_ANALYTICS=true
RUN flutter config --no-analytics --enable-web >/dev/null && flutter precache --web
WORKDIR /src/client
COPY client/pubspec.yaml client/pubspec.lock ./
RUN flutter pub get
COPY client/ ./
# API is same-origin behind Caddy, so API_BASE_URL is empty.
# GOOGLE_CLIENT_ID is optional here: the server's /api/auth/config supplies it.
ARG GOOGLE_CLIENT_ID=
# BUILD_ID (e.g. the commit sha; defaults to the build time) is compiled in and
# written to /build.json: a tab still running an older build sees the
# mismatch and reloads (lib/boot/app_version.dart).
ARG BUILD_ID=
RUN B="${BUILD_ID:-$(date -u +%Y%m%d%H%M%S)}" \
 && flutter build web --release \
      --dart-define=API_BASE_URL= \
      --dart-define=GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID} \
      --dart-define=BUILD_ID=$B \
 && printf '{"build":"%s"}\n' "$B" > build/web/build.json \
 && sh tool/hash_fonts.sh build/web
# Ship less, compress once at build time with the strongest settings (Caddy
# serves the .br/.zst/.gz siblings via `precompressed`; on-the-fly zstd/gzip
# is ~40% larger for main.dart.js). CanvasKit loads from gstatic, so its
# local copies are never fetched: drop their debug symbols. build.json and
# other tiny files stay uncompressed (below 1 KB; `encode` still covers them).
RUN cd build/web \
 && find canvaskit -name '*.symbols' -delete \
 && find . -path ./canvaskit -prune -o -type f -size +1k \
      \( -name '*.js' -o -name '*.wasm' -o -name '*.mjs' -o -name '*.json' \
         -o -name '*.html' -o -name '*.svg' -o -name '*.otf' -o -name '*.ttf' \
         -o -name 'NOTICES' \) -print \
    | while read -r f; do \
        brotli -q 11 -k -f "$f" && zstd -19 -q -k -f "$f" && gzip -9 -k -n -f "$f"; \
      done

# 2.11+: precompressed files return 200 (2.10.x answered 206, caddy#7250).
FROM caddy:2.11-alpine
COPY --from=build /src/client/build/web /srv/web
COPY deploy/Caddyfile /etc/caddy/Caddyfile
