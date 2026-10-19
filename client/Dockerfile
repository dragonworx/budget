# Budget web client baked into a Caddy image (static files + reverse proxy).
# Build context: repo root  (docker build -f client/Dockerfile .)
# Flutter is installed from its git tag so the image matches the client's SDK
# constraint (prebuilt Flutter images lag behind stable releases).
FROM debian:bookworm-slim AS build
ARG FLUTTER_VERSION=3.47.7
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils \
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
RUN flutter build web --release \
      --dart-define=API_BASE_URL= \
      --dart-define=GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}

FROM caddy:2-alpine
COPY --from=build /src/client/build/web /srv/web
COPY deploy/Caddyfile /etc/caddy/Caddyfile
