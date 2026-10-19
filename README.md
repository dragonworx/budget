# Budget Tool

Flutter web budget app with a Dart API and Postgres (Docker).

## Prerequisites

- [Docker Desktop](https://docs.docker.com/get-docker/) (Compose v2) — must be running (`docker info` succeeds)
- [Dart](https://dart.dev/get-dart) SDK
- [Flutter](https://flutter.dev/docs/get-started/install) (web enabled; `flutter` on `PATH`)

Copy env if needed: `cp .env.example .env`

If Docker Desktop fails to start with a privilege / `vmnetd` error, open Docker Desktop, accept the macOS password prompt to repair networking, then retry `make dev`.

## Run

```bash
make dev
```

This starts Postgres, runs migrations (when available), starts the API in the background, then launches Flutter web in the foreground.

| Service | URL |
|---------|-----|
| API     | http://localhost:8080 |
| Web     | http://localhost:5080 |

If the web port is busy: `make dev WEB_PORT=5081`

Ctrl+C stops Flutter only. Cleanup:

```bash
make stop
```

## Database

Postgres data lives in the Docker named volume `budget_pgdata` and survives `make down` / `make stop`.

Reset all DB data (destructive):

```bash
make db-reset
```

## Other targets

```bash
make help
```

## Deploy (production)

One Docker Compose stack: Caddy (TLS, static web app, load balancer) → API replicas → Postgres, with a one-off `migrate` job.

```bash
cp deploy/.env.prod.example deploy/.env.prod   # fill in domain, Google client id, secrets
docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env.prod up -d --build
```

Already running Caddy on the host? Add `-f deploy/docker-compose.host.yml` and paste
`deploy/caddy-host-snippet` into the host Caddyfile. Backups: `scripts/backup.sh`.
Full guide (VPS, Route 53 DNS, Google client, upgrades, backups): [docs/deploy.md](docs/deploy.md).
