# Budget API: compiled to a native executable (server + migrate).
# Build context: server/   (docker build -f server/Dockerfile server)
FROM dart:stable AS build
WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY . .
RUN dart pub get --offline \
 && mkdir -p /out \
 && dart compile exe bin/server.dart -o /out/server \
 && dart compile exe bin/migrate.dart -o /out/migrate

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home /app budget
WORKDIR /app
COPY --from=build /out/ /app/bin/
COPY migrations /app/migrations
USER budget
ENV API_HOST=0.0.0.0 API_PORT=8080 APP_ENV=production
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/health || exit 1
CMD ["/app/bin/server"]
