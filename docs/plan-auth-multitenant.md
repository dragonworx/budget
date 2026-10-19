# Plan: Google sign-in + multi-tenant sharing + real-time sync

Status: plan only (nothing implemented). Base commit: f8f4509.

## 0. Current architecture (what we're changing)

- **Server**: Dart `shelf` + `shelf_router` (`server/bin/server.dart`, `server/lib/api/router.dart`).
  Routers mounted at `/api/projects`, `/api/accounts`, `/api/transactions`, plus `/health`.
  Account sub-routes live in `accounts.dart`, `balance.dart`, `solve.dart`, `goal.dart`, `scenarios.dart`.
  CORS is `*`. Middleware: cors, noStoreApi, error, logRequests.
- **DB**: one `postgres` v3 `Connection` shared by the whole process (`lib/db.dart`) — not a pool.
  Repos (`lib/repo/*_repo.dart`) take a `Session` and use raw SQL. No notion of a user anywhere.
- **Migrations**: `server/migrations/00N_*.sql`, applied by `bin/migrate.dart` / `applyMigrations` and
  tracked in `schema_migrations`. Existing: 001–005, 007 (006 unused). New work starts at **008**.
- **Tables**: `projects` (globally unique lower(name)!), `accounts` (project_id), `transactions`
  (renamed from streams; account_id), `skipped_occurrences`, transfers (peer-account links), `scenarios` (account_id).
- **Client**: Flutter web, Riverpod 2 (`client/lib/state/providers.dart`), go_router (`app.dart`),
  `ApiClient` (`data/api_client.dart`) using `package:http`, base URL from
  `--dart-define=API_BASE_URL` (default `http://localhost:8080`); dev builds use same-origin via proxy.
  Boot loader in `client/lib/boot/` tracks requests via `ApiClient.stats`.
- **Dev**: `dev.sh` tmux `budget` (db via `docker-compose.yml`, api with inotify restart, web build,
  `dev-proxy.js` on :8000 routing `/api/*`,`/health` → :8080, rest → web), ngrok tunnel + watchdog.

## 1. Key decisions

| Decision | Choice | Why |
|---|---|---|
| Google flow | **Google Identity Services (GIS) ID-token** ("Sign in with Google" button) | No client secret, no redirect handling; we only need identity (email, sub, name, picture), not Google API scopes. |
| Token verification | Server verifies JWT (RS256) against `https://www.googleapis.com/oauth2/v3/certs` (JWKS cached per `Cache-Control` max-age), checks `aud == GOOGLE_CLIENT_ID`, `iss ∈ {accounts.google.com, https://accounts.google.com}`, `exp`, `email_verified`. | Standard; no per-request Google call. Library: `package:jose` or `dart_jsonwebtoken` + `pointycastle`. |
| Session | **Opaque random session id in an HttpOnly, Secure, SameSite=Lax cookie**, stored hashed (sha256) in `sessions` table. Sliding expiry (30 days, touched at most once/hour). | Same-origin deployment (Caddy serves web + API) makes cookies simplest and safest (no token in JS, instant revocation/logout). Stateless *servers*: any replica validates against Postgres; cheap indexed lookup + small in-process LRU (60 s). JWT rejected: revocation/logout and "remove user from allowlist" need server state anyway. |
| CSRF | SameSite=Lax + require `X-Requested-With: budget` (or `Content-Type: application/json`) on mutations + Origin check against `PUBLIC_ORIGIN`. | Cookie auth needs CSRF defence; CORS tightened from `*` to explicit origin (or same-origin only). |
| Bearer fallback | `Authorization: Bearer <session id>` accepted too (same table). | Enables tests, curl and a future native client without a second auth system. |
| Allowlist | Env `AUTH_ALLOWLIST` (emails and `@domain` entries) seeds; DB table `allowed_emails` managed by admins in-app. Admins always allowed. **Pending invites also grant sign-in** (configurable `AUTH_INVITES_BYPASS_ALLOWLIST=true`). Empty allowlist + `AUTH_OPEN_SIGNUP=false` ⇒ admins + invitees only. | Configurable, and sharing with a new person "just works" if the owner invites them. |
| Admin | `ADMIN_EMAILS` (default `musicartscience@gmail.com`), re-evaluated at every login → `users.is_admin`. | Env is the source of truth; can't be lost via DB edits. |
| Dev bypass | `AUTH_DEV_BYPASS=true` → `POST /api/auth/dev-login` creates a session for the first `ADMIN_EMAILS` user; client shows "Continue as admin (dev)". | Guards: refuses to start if `APP_ENV=production` and bypass is on; endpoint only registered when enabled; logs a loud banner; `/api/auth/config` advertises it so client needs no rebuild. |
| Tenancy | **Tenant = user**; projects owned by a user, shared via `project_members`. Accounts inherit project access; optional **account-level shares** for sharing a single account. | Matches "owned per Google account"; row-level scoping via joins, no schema-per-tenant (scales to many small tenants in one DB). |
| Authz location | Single `Authz` service (`lib/auth/authz.dart`) with `requireProject(user, id, Role.min)` / `requireAccount(...)` / `requireTransaction(...)`/`requireScenario(...)` resolving the effective role in **one SQL query**; called at the top of every handler. Repo list queries take `userId` and join membership. 404 (not 403) for no access to avoid leaking existence. | Central, testable, easy to audit with a route-coverage test. |
| Real-time | **SSE** `GET /api/events?projects=...` (or WS later) from each API replica; cross-replica fan-out via **Postgres LISTEN/NOTIFY** on channel `budget_events`. Events are invalidation hints (ids + version), client refetches. | SSE works through Caddy/ngrok, auto-reconnects, simple in shelf (streamed response); writes are already REST. NOTIFY needs no extra infra (Redis optional later). Hints avoid authz leaks and payload size limits (8 KB NOTIFY). |
| Conflicts | Optimistic concurrency: `version INT` column on projects/accounts/transactions/scenarios; PATCH sends `If-Match`/`version`, server returns 409 with current row; client shows "Changed by X — reload/overwrite". | Cheap, prevents silent lost updates when two people edit. |
| DB access | Replace single `Connection` with `Pool` (`Pool.withEndpoints`, max `DB_POOL_SIZE`=10) plus one dedicated connection for LISTEN. | Required for concurrency and multi-user load. |
| Deploy | Docker Compose: `caddy` (TLS, static web, reverse proxy) → `api` (N replicas, stateless) → `db` (Postgres 16) + one-shot `migrate` service. | User already runs a VPS with Caddy + Route 53. |

## 2. Data model (migrations 008–011)

**008_users_sessions.sql**
```sql
CREATE TABLE users (
  id UUID PRIMARY KEY,
  google_sub TEXT UNIQUE,              -- null for dev-bypass-created admin until first real login
  email CITEXT NOT NULL UNIQUE,        -- CREATE EXTENSION citext (or lower(email) unique index)
  name TEXT, picture_url TEXT,
  is_admin BOOL NOT NULL DEFAULT false,
  disabled BOOL NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_login_at TIMESTAMPTZ);
CREATE TABLE sessions (
  id_hash BYTEA PRIMARY KEY,           -- sha256(token)
  user_id UUID NOT NULL REFERENCES users ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  user_agent TEXT, ip INET, is_dev BOOL NOT NULL DEFAULT false);
CREATE INDEX ON sessions (user_id); CREATE INDEX ON sessions (expires_at);
CREATE TABLE allowed_emails (pattern CITEXT PRIMARY KEY, added_by UUID REFERENCES users, created_at TIMESTAMPTZ DEFAULT now());
```

**009_ownership.sql** (scopes existing data)
```sql
ALTER TABLE projects ADD COLUMN owner_id UUID REFERENCES users;
-- seed admin user from first ADMIN_EMAILS (migrate.dart passes it as a setting, default musicartscience@gmail.com)
INSERT INTO users (id,email,is_admin) VALUES (gen_random_uuid(), current_setting('budget.admin_email'), true) ON CONFLICT (email) DO NOTHING;
UPDATE projects SET owner_id = (SELECT id FROM users WHERE email = current_setting('budget.admin_email')) WHERE owner_id IS NULL;
ALTER TABLE projects ALTER COLUMN owner_id SET NOT NULL;
DROP INDEX projects_name_lower_uidx;                       -- names unique per owner, not globally
CREATE UNIQUE INDEX projects_owner_name_uidx ON projects (owner_id, lower(name));
-- audit fields on projects, accounts, transactions, scenarios:
--   created_by UUID, updated_by UUID, updated_at TIMESTAMPTZ DEFAULT now(), version INT NOT NULL DEFAULT 1
-- backfill created_by/updated_by = admin.
```
`migrate.dart` gets a small "settings" hook (`SET budget.admin_email = ...` before running files).
On first Google login with that email, `google_sub` is filled in (link by verified email).

**010_sharing.sql**
```sql
CREATE TYPE member_role AS ENUM ('viewer','editor','owner');
CREATE TABLE project_members (
  project_id UUID REFERENCES projects ON DELETE CASCADE,
  user_id UUID REFERENCES users ON DELETE CASCADE,
  role member_role NOT NULL, added_by UUID REFERENCES users, created_at TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (project_id, user_id));                     -- owner also inserted here (role owner) for uniform joins
CREATE TABLE account_shares (
  account_id UUID REFERENCES accounts ON DELETE CASCADE,
  user_id UUID REFERENCES users ON DELETE CASCADE,
  role member_role NOT NULL CHECK (role <> 'owner'), added_by UUID, created_at TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (account_id, user_id));
CREATE TABLE invites (
  id UUID PRIMARY KEY, token_hash BYTEA UNIQUE NOT NULL,
  email CITEXT NOT NULL,
  project_id UUID REFERENCES projects ON DELETE CASCADE,
  account_id UUID REFERENCES accounts ON DELETE CASCADE,
  role member_role NOT NULL, invited_by UUID NOT NULL REFERENCES users,
  created_at TIMESTAMPTZ DEFAULT now(), expires_at TIMESTAMPTZ NOT NULL,
  accepted_at TIMESTAMPTZ, revoked_at TIMESTAMPTZ,
  CHECK ((project_id IS NULL) <> (account_id IS NULL)));
CREATE INDEX ON invites (email) WHERE accepted_at IS NULL AND revoked_at IS NULL;
```
Pending invites for emails with no user are auto-accepted on that email's first sign-in.

**011_audit_log.sql** (optional, small): `audit_log(id bigserial, at, user_id, project_id, action, entity, entity_id, detail jsonb)` for share/revoke/delete events. Also the event `seq` source for resync.

Effective role for an account = max(project_members.role, account_shares.role). A user with only an account share sees the project as a "shared with me" container listing just that account (read-only project metadata).

## 3. Authz model

- `authMiddleware` (after CORS, before routers): resolves cookie/bearer → `AuthContext(user, session)` in `request.context['auth']`; 401 for `/api/*` except `/api/auth/*` and `/health`.
- `Authz` (one class, one file) with helpers returning the entity's project id + effective role:
  - `requireProject(ctx, projectId, min)` — `project_members`.
  - `requireAccount(ctx, accountId, min)` — join accounts → project_members ∪ account_shares.
  - `requireTransaction(ctx, txId, min)` → its account. `requireScenario(...)` → its account.
  - Transfers: creating/updating a transfer needs **editor on both** accounts; peer shown only if readable.
- Role matrix: viewer = all GETs, balance/insights/project/solve/goal (compute-only POSTs); editor = create/update/delete accounts, transactions, skips, scenarios, imports, reorder; owner = rename/delete project, manage members/invites, transfer ownership. Account-share editor cannot delete the account or move it.
- Endpoint mapping (every current route):
  - `GET /api/projects` → list where member or has an account share (+ `role`, `owner`, `shared` fields).
  - `POST /api/projects` → owner = me, insert owner member.
  - `GET/PATCH/DELETE /api/projects/<id>` → viewer/owner/owner. `GET/POST /api/projects/<id>/accounts` → viewer (filtered to readable accounts) / editor.
  - `/api/accounts/<id>` GET viewer, PATCH editor, DELETE project editor; `/<id>/transactions*`, `/reorder-transactions` editor (GET viewer); `/<id>/balance`, `/insights`, `POST /<id>/project`, `/solve`, `/goal` viewer; `/<id>/scenarios` GET viewer, writes editor.
  - `/api/transactions/<id>` GET viewer, PATCH/DELETE/skips editor (via account).
- **Coverage test**: a test enumerates every registered route and asserts each returns 401 unauthenticated and 404 for a non-member user (prevents a future endpoint shipping unscoped).
- Admin endpoints `/api/admin/*` (users list, disable, allowlist CRUD) require `is_admin`. Admins do **not** implicitly see other tenants' data.

## 4. Auth flow

1. Client boot calls `GET /api/auth/config` → `{googleClientId, devBypass, user|null}` (also acts as "me").
2. Not signed in → `/sign-in` route: GIS button rendered via `google_identity_services_web` / `google_sign_in_web` `renderButton` (or a small JS interop to `google.accounts.id`); One Tap optional.
3. GIS returns ID token → `POST /api/auth/google {credential}`.
4. Server verifies token (JWKS cache), checks `email_verified`, allowlist (env + DB + admin + pending invite), upserts user (link by sub, else by email), refreshes `is_admin`, accepts pending invites, creates session, `Set-Cookie: budget_session=<token>; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=2592000`. Returns user.
5. Refresh: sliding — middleware extends `expires_at` when older than 1 day; no Google refresh token needed. 401 anywhere → client clears state and routes to sign-in (keeping intended URL).
6. Logout: `POST /api/auth/logout` deletes session row, clears cookie, client calls `google.accounts.id.disableAutoSelect()`. "Sign out everywhere" deletes all user sessions. Disabling a user/removing from allowlist deletes their sessions.
7. Dev bypass: `POST /api/auth/dev-login` only exists when `AUTH_DEV_BYPASS=true` **and** `APP_ENV != production` (server exits at startup otherwise). Cookie `Secure` dropped when `PUBLIC_ORIGIN` is http://localhost. The ngrok dev URL keeps bypass on until the real client id is set, then can use real Google.
8. `SESSION_SECRET` used to HMAC session tokens (token = random 32 bytes; stored hash = HMAC(secret, token)) and invite tokens, so a DB leak alone doesn't yield usable tokens.

## 5. Sharing UX

- **Share dialog** (project menu and account menu → "Share…"): email field + role dropdown (Viewer/Editor), list of members with avatar, role dropdown, remove (×); pending invites section with "Copy link", "Resend"(copy), "Revoke". Owner row fixed; "Transfer ownership" (owner only, confirm).
- Invites: `POST /api/projects/<id>/invites {email, role}` (or `/api/accounts/<id>/invites`). If user exists → membership added immediately + event; else pending invite + shareable link `/invite/<token>` (no email sending in v1; optional SMTP later — question for user). Allowlist interplay: inviting adds a one-shot allowance for that email (if `AUTH_INVITES_BYPASS_ALLOWLIST`), otherwise the dialog warns "not on allowlist — ask an admin".
- Projects page: "My projects" and "Shared with me" sections, owner avatar badges, role chip; viewers see disabled edit controls (client gates via `role` field, server enforces).
- Revocation: removing a member deletes row, emits `membership.revoked` to that user's stream → their client drops the project and navigates away with a snackbar.
- "Leave project" for non-owners. Account menu shows signed-in user avatar + Sign out; admins see "Admin" (users + allowlist).

## 6. Real-time design

- Endpoint: `GET /api/events` (SSE, `text/event-stream`, heartbeat comment every 25 s, `retry: 3000`). Subscribes the session's user to: their user channel + every project they can read (recomputed on membership events).
- Writes: after a successful mutation commit, handler calls `events.publish(Event)` → `SELECT pg_notify('budget_events', json)` inside the same transaction (delivered only on commit). Each replica's dedicated LISTEN connection receives and fans out to local subscribers whose access set contains the project/account (and re-check account-share filtering).
- Event shape: `{seq, type, projectId, accountId?, entityId, version, actorId, at}`. Types: `project.created|updated|deleted`, `account.created|updated|deleted|reordered`, `transaction.created|updated|deleted`, `transactions.imported`, `skip.changed`, `scenario.created|updated|deleted`, `membership.added|changed|revoked`, `invite.changed`.
- `seq` from a global sequence/`audit_log.id`; SSE `id:` = seq. Reconnect sends `Last-Event-ID`; server replays from `audit_log` if within retention window (e.g. 24 h / 10k events), else sends `resync` → client invalidates all providers.
- Client: `RealtimeService` (EventSource via `package:web`) → maps events to `ref.invalidate(...)` of `projectsProvider`, `accountsProvider(projectId)`, `transactionsProvider(accountId)`, `balanceProvider`, `insightsProvider`, scenarios. Events where `actorId == me && from this tab` (client sends `X-Client-Id`, echoed in event) are skipped to avoid double refresh. Debounce invalidations 150 ms. Connection status dot in app bar; on visibility regain → reconnect.
- Optimistic updates: existing notifiers already update local state from responses; add optimistic local apply + rollback on error for transaction edits/toggles. 409 version conflicts → dialog with server copy.
- Scale: NOTIFY throughput is fine for this domain (thousands/s). If needed later, swap the fan-out bus for Redis pub/sub behind the same `EventBus` interface.

## 7. Deployment

- `deploy/docker-compose.prod.yml`:
  - `db`: postgres:16-alpine, volume, healthcheck `pg_isready`, not exposed publicly.
  - `migrate`: api image running `dart bin/migrate.dart` (`depends_on: db healthy`), restart: no.
  - `api`: `server/Dockerfile` (multi-stage `dart compile exe` → `scratch`/debian-slim), `deploy.replicas: ${API_REPLICAS:-2}`, `depends_on: migrate completed_successfully`, healthcheck `GET /health` (checks DB) and `GET /ready`.
  - `caddy`: `caddy:2` with `deploy/Caddyfile`: `{$SITE_DOMAIN} { encode gzip; handle /api/* { reverse_proxy api:8080 { lb_policy round_robin; health_uri /health; flush_interval -1 } } handle /health {...} handle { root * /srv/web; try_files {path} /index.html; file_server } }` plus security headers (CSP allowing `accounts.google.com`, HSTS). Web built in `client/Dockerfile` (flutter build web, `API_BASE_URL=''` same-origin) copied into the caddy image or a volume.
  - Alternative for user's existing host Caddy: compose without caddy, api published on 127.0.0.1, snippet provided for their Caddyfile. Route 53: A/AAAA record → VPS; Caddy gets Let's Encrypt cert automatically.
- `.env.example` (root) consumed by both dev (`dev.sh` sources it) and prod compose.
- Graceful shutdown on SIGTERM (close SSE streams with `retry`, drain pool). Request logging JSON in prod. Rate limit `/api/auth/*` (in-proc token bucket per IP; Caddy optional).
- Backups: `pg_dump` cron sidecar or documented script → S3 (user has AWS).

### Env vars (`.env.example`)
```
APP_ENV=development                 # production disables dev bypass hard
PUBLIC_ORIGIN=https://unsaid-generic-jubilance.ngrok-free.dev   # used for CORS/Origin check & cookie Secure
GOOGLE_CLIENT_ID=xxxxxxxx.apps.googleusercontent.com
ADMIN_EMAILS=musicartscience@gmail.com
AUTH_ALLOWLIST=                     # comma list: a@b.com,@example.com ; empty = admins+invitees only
AUTH_OPEN_SIGNUP=false              # true = any verified Google account may sign in
AUTH_INVITES_BYPASS_ALLOWLIST=true
AUTH_DEV_BYPASS=true                # dev only; server refuses to start with APP_ENV=production
SESSION_SECRET=change-me-64-hex     # openssl rand -hex 32
SESSION_TTL_DAYS=30
DATABASE_URL=postgres://budget:budget@db:5432/budget
DB_POOL_SIZE=10
API_HOST=0.0.0.0
API_PORT=8080
# prod compose
SITE_DOMAIN=budget.example.com
POSTGRES_PASSWORD=change-me
API_REPLICAS=2
```
Google client: Google Cloud Console → APIs & Services → Credentials → Create credentials → OAuth client ID → **Web application** (configure OAuth consent screen first: External, app name, support email; while in "Testing" add test users or publish). **Authorized JavaScript origins**: `https://unsaid-generic-jubilance.ngrok-free.dev`, `http://localhost:8000`, `http://localhost` (GIS requires both forms for localhost ports), `http://127.0.0.1:8000` is NOT accepted reliably—use localhost; later `https://<SITE_DOMAIN>`. No redirect URIs needed for the ID-token button flow.

## 8. Phases & parallel workstreams

Each phase ends with tests green and one commit (`feat(auth): P1 ...`). Workstreams list owned files; shared files have a single owner per phase, others request changes via that owner.

### P1 — Server auth foundation (users, sessions, dev bypass, existing data scoped to admin)
- **W1a DB & config**: `server/migrations/008_users_sessions.sql`, `009_ownership.sql`, `server/lib/db.dart` (Pool), `server/lib/config.dart`, `server/bin/migrate.dart` (settings hook), `server/bin/server.dart`, `.env.example`, `dev.sh` (source .env).
- **W1b Google verify + sessions**: `server/lib/auth/google_verifier.dart`, `jwks_cache.dart`, `session_store.dart`, `allowlist.dart`, `server/lib/repo/user_repo.dart`, `server/pubspec.yaml`, tests `server/test/auth/*`.
- **W1c Auth API & middleware**: `server/lib/api/auth.dart` (config/google/dev-login/logout/me), `server/lib/auth/middleware.dart`, `server/lib/api/router.dart` (mount + CORS/CSRF), `server/lib/api/json_helpers.dart` (auth helpers).
- Interim: all existing endpoints require login; data owned by admin; until P3, authz = "must be owner" via a simple project-owner check helper so nothing leaks between users.

### P2 — Client sign-in UI, auth state, dev mode
- **W2a Auth state & API**: `client/lib/data/api_client.dart` (credentials `include`/`BrowserClient.withCredentials`, 401 handler, `X-Client-Id`, `X-Requested-With`), `client/lib/data/auth_repository.dart`, `client/lib/state/auth_providers.dart`.
- **W2b Sign-in UI**: `client/lib/features/auth/sign_in_page.dart`, `google_button_web.dart`/`_stub.dart`, `client/web/index.html` (GIS script), `client/pubspec.yaml`.
- **W2c Routing & shell**: `client/lib/app.dart` (go_router redirect guard, `/sign-in`, `/invite/:token`), `client/lib/widgets/user_menu.dart`, `client/lib/boot/*` (add "Signing in" stage).

### P3 — Tenancy/membership, authz on all endpoints, sharing API
- **W3a Schema & authz core**: `server/migrations/010_sharing.sql`, `011_audit_log.sql`, `server/lib/auth/authz.dart`, `server/lib/repo/membership_repo.dart`, `server/lib/repo/invite_repo.dart`.
- **W3b Scope project/account routes**: `server/lib/api/projects.dart`, `accounts.dart`, `balance.dart`, `solve.dart`, `goal.dart`, `server/lib/repo/project_repo.dart`, `account_repo.dart`.
- **W3c Scope transaction/scenario routes + version/409**: `server/lib/api/transactions.dart`, `scenarios.dart`, `server/lib/repo/transaction_repo.dart`, `scenario_repo.dart`.
- **W3d Sharing & admin API**: `server/lib/api/sharing.dart`, `server/lib/api/admin.dart`, route-coverage + authz tests `server/test/authz/*`. (router.dart mount lines owned by W3a lead; trivial merge.)

### P4 — Sharing UI
- **W4a Share dialog & invites**: `client/lib/features/sharing/share_dialog.dart`, `invite_accept_page.dart`, `client/lib/data/sharing_repository.dart`.
- **W4b Projects page & role gating**: `client/lib/features/projects/*`, `client/lib/data/models.dart` (role/owner fields), `client/lib/widgets/account_picker.dart`, read-only gating in `features/timeline/timeline_page.dart`, `features/transactions/*`.
- **W4c Admin page**: `client/lib/features/admin/admin_page.dart` (users, allowlist).

### P5 — Real-time sync
- **W5a Server bus + SSE**: `server/lib/realtime/event_bus.dart`, `pg_listener.dart`, `server/lib/api/events.dart`, publish calls in repos/handlers (touches W3 files — done after P3 merged; single owner).
- **W5b Client realtime**: `client/lib/data/realtime_service.dart` (+ web/stub), `client/lib/state/realtime_providers.dart`, invalidation map; `client/lib/state/providers.dart` (optimistic updates, conflict handling) owned here; status dot widget.
- **W5c Tests**: two-replica integration test (two server processes, one DB) asserting cross-instance delivery and replay.

### P6 — Production deployment & hardening
- **W6a Containers**: `server/Dockerfile`, `client/Dockerfile`, `.dockerignore`, `deploy/docker-compose.prod.yml`, `deploy/Caddyfile`, `deploy/caddy-snippet-host.caddy`.
- **W6b Docs & ops**: `docs/deploy.md` (VPS, Route 53, Google client, backups), `README.md`, `scripts/backup.sh`.
- **W6c Hardening**: rate limiting, security headers/CSP, `/ready`, structured logs, session cleanup job, graceful shutdown (`server/bin/server.dart`, `server/lib/api/router.dart`).

## 9. Testing strategy
- Unit: token verifier with locally generated RSA keys + fake JWKS (exp/aud/iss/email_verified cases); allowlist matching; session hashing/expiry; role resolution matrix.
- Integration (Dart `test` against a throwaway Postgres DB `budget_test`): every route × {anon, non-member, viewer, editor, owner}; generated route-coverage test; migration 009 on a copy of current dev data (all projects → admin, counts unchanged).
- Dev bypass guard test: config with `APP_ENV=production` + bypass → startup throws.
- Realtime: SSE client in tests, NOTIFY across two server instances, Last-Event-ID replay, revocation drops subscription.
- Client: widget tests for sign-in page, share dialog, role gating; existing 170+ tests kept green with a fake authed ApiClient. Manual/browser checks on the ngrok URL with dev bypass, then real Google once configured.

## 10. Risks
- **Migration 009** changes project-name uniqueness and requires an admin user; run on a DB backup first. Dev data all becomes the admin's.
- Single-connection code paths that use transactions (`conn.runTx`) must be ported to Pool carefully.
- **ngrok free domain + GIS**: the origin must be registered exactly; ngrok interstitial may interfere with first load (already handled in proxy?) — verify. Third-party cookie phase-out affects One Tap (use FedCM-enabled GIS; button flow is fine).
- Cookie `Secure` on http://localhost — handled via PUBLIC_ORIGIN scheme.
- Transfers across projects with different members could leak peer account names — enforce readable-peer check.
- SSE connections per replica (memory) and Caddy `flush_interval -1` needed; ngrok free request quota with long-lived streams (one stream per tab; fine).
- Existing global unique project name in client error handling must change to per-owner.
- Scope creep: email delivery of invites deferred.

## 11. Open questions for the user
1. Should invited emails be allowed to sign in even if not on the allowlist (default: yes)?
2. Send invite emails (needs SMTP/SES) or just copyable invite links in v1 (default: links)?
3. Production domain name (for `SITE_DOMAIN` and the Google origin), and use the existing host Caddy or the bundled Caddy container?
