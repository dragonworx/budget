# Deploying Budget

The whole site (every user's projects, i.e. all tenants) runs as one Docker Compose stack:

```
browser ──https──> caddy ──/api/*, /health──> api ×N (stateless) ──> db (Postgres 16, volume)
                     └── everything else ──> /srv/web (Flutter build)
migrate (one-off) ──> db         (runs before api starts)
```

| File | Purpose |
|---|---|
| `server/Dockerfile` | API image: `dart compile exe` → debian-slim with `/app/bin/server` and `/app/bin/migrate` + `migrations/`. |
| `client/Dockerfile` | Builds the Flutter web app (same-origin API) and bakes it into a `caddy:2` image with `deploy/Caddyfile`. |
| `deploy/docker-compose.prod.yml` | `db`, `migrate`, `api` (`API_REPLICAS`, default 2), `caddy`. |
| `deploy/docker-compose.host.yml` | Override when the VPS already runs Caddy on the host. |
| `deploy/caddy-host-snippet` | Site block for that host Caddy. |
| `deploy/.env.prod.example` | Settings template → `deploy/.env.prod` (never commit). |
| `scripts/backup.sh` | `pg_dump` → gzip, rotation, optional S3 copy. |

## 1. Server prerequisites

A Linux VPS with Docker Engine + Compose v2 (`docker compose version`), ports 80 and 443 open,
about 1 GB RAM (building the web image needs ~4 GB; build elsewhere if smaller, see §7).

## 2. DNS (Route 53)

Route 53 → Hosted zones → your domain → Create record: name `budget` (or apex), type **A**,
value = VPS IPv4 (add **AAAA** for IPv6), TTL 300. Check with `dig +short budget.example.com`.
Caddy obtains the Let's Encrypt certificate automatically once DNS points at the VPS.

## 3. Google OAuth client

Google Cloud Console → APIs & Services → OAuth consent screen (External; app name, support
email; add test users while in Testing, or Publish). Then Credentials → Create credentials →
OAuth client ID → **Web application** → Authorized JavaScript origins:
`https://budget.example.com` (plus `http://localhost:8000` and `http://localhost` for dev).
No redirect URIs. Copy the client id into `GOOGLE_CLIENT_ID`. The web app reads it at runtime
from `/api/auth/config`, so changing it only needs an API restart, not a web rebuild.

## 4. Configure

```bash
git clone <repo> /opt/budget && cd /opt/budget
cp deploy/.env.prod.example deploy/.env.prod
openssl rand -hex 32   # -> SESSION_SECRET
openssl rand -hex 24   # -> POSTGRES_PASSWORD
$EDITOR deploy/.env.prod   # SITE_DOMAIN, PUBLIC_ORIGIN=https://SITE_DOMAIN, GOOGLE_CLIENT_ID, ADMIN_EMAILS, ...
```

`APP_ENV=production` makes the API refuse to start without `SESSION_SECRET`, `GOOGLE_CLIENT_ID`
and an https `PUBLIC_ORIGIN`. The dev sign-in bypass is forced off by the compose file.

## 5a. Start: bundled Caddy (Caddy owns 80/443)

```bash
docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env.prod up -d --build
docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env.prod ps
curl -fsS https://budget.example.com/health        # {"ok":true}
```

## 5b. Start: existing host Caddy

The bundled Caddy then serves plain HTTP on `127.0.0.1:${WEB_PORT:-8081}` only (it still
load-balances the API replicas and serves the web files); the host Caddy terminates TLS.

```bash
docker compose -f deploy/docker-compose.prod.yml -f deploy/docker-compose.host.yml \
  --env-file deploy/.env.prod up -d --build
# paste deploy/caddy-host-snippet into /etc/caddy/Caddyfile (set your domain), then
sudo systemctl reload caddy
```

`SITE_DOMAIN` must still be set (it's used for nothing else in this variant, but the file
requires it); `PUBLIC_ORIGIN` must be the public https URL.

## 6. Operations

- **Health**: `/health` is liveness (process + DB). `/ready` is readiness: 200 only when the DB pool
  and the LISTEN connection are healthy and the replica is not draining (503 otherwise). The compose
  healthcheck uses `/ready`; Caddy only routes to healthy replicas (switching Caddy's `health_uri`
  to `/ready` is recommended) and discovers replicas via Docker DNS every 5 s.
- **Hardening env** (defaults in brackets): `TRUSTED_PROXIES` (CIDRs allowed to set X-Forwarded-For),
  `RATE_LIMIT_AUTH_PER_MIN` [20, per IP on /api/auth/*], `RATE_LIMIT_PER_MIN` [600, per session],
  `SESSION_CACHE_TTL_SECONDS` [10, 0 disables], `SHUTDOWN_GRACE_SECONDS` [10],
  `CLEANUP_INTERVAL_MINUTES` [60]. Rate limits are in memory **per replica**, so the effective limit is
  roughly N× with N replicas. On SIGTERM a replica stops accepting, sends SSE clients a `reconnect`
  event, drains in-flight requests, then closes the pool. Logs are JSON lines with reqId/userId/ms.
- **Scale**: `API_REPLICAS=4 docker compose ... up -d` (stateless; sessions live in Postgres).
- **Real-time**: Caddy uses `flush_interval -1`, so `/api/events` (SSE) streams without buffering.
- **Logs**: `docker compose -f deploy/docker-compose.prod.yml logs -f api caddy`.
- **Upgrade**: `git pull && docker compose ... up -d --build`. `migrate` re-runs first and only applies
  new files; api replicas restart after it succeeds.
- **Migrations by hand**: `docker compose ... run --rm migrate`.
- **psql**: `docker compose ... exec db psql -U budget -d budget`.

## 7. Building images elsewhere

Small VPS? Build on a bigger machine or CI and push to a registry, then set `API_IMAGE` and
`WEB_IMAGE` in `deploy/.env.prod` and run `docker compose ... pull && ... up -d` (no `--build`):

```bash
docker build -t ghcr.io/you/budget-api:1 -f server/Dockerfile server
docker build -t ghcr.io/you/budget-web:1 -f client/Dockerfile .
```

## 8. Backups

```bash
scripts/backup.sh                                     # ./backups/budget-<time>.sql.gz, keeps 14
BACKUP_DIR=/var/backups/budget S3_URI=s3://bucket/budget scripts/backup.sh
# cron: 15 3 * * * cd /opt/budget && scripts/backup.sh >> /var/log/budget-backup.log 2>&1
```

Restore into a running stack (overwrites data):
`gunzip -c backups/FILE.sql.gz | docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env.prod exec -T db psql -U budget -d budget`

Data lives in the `budget_pgdata` volume; `docker compose down` keeps it, `down -v` deletes it.

## 9. Local smoke test (no TLS)

```bash
cat > /tmp/budget-local.env <<'X'
APP_ENV=staging
SITE_DOMAIN=budget.localtest
SITE_ADDRESS=http://budget.localtest
PUBLIC_ORIGIN=http://budget.localtest:18080
SESSION_SECRET=0123456789abcdef0123456789abcdef
POSTGRES_PASSWORD=localtest
HTTP_PORT=18080
HTTPS_PORT=18443
X
docker compose -p budget-smoke -f deploy/docker-compose.prod.yml --env-file /tmp/budget-local.env up -d --build
curl -H 'Host: budget.localtest' http://127.0.0.1:18080/health
docker compose -p budget-smoke -f deploy/docker-compose.prod.yml --env-file /tmp/budget-local.env down -v
```
