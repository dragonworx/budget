# Budget Tool — local development orchestration
# Prefer: make dev  (db + migrate + API bg + Flutter fg)
# Cleanup: make stop

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

COMPOSE := docker compose
DB_SERVICE := db
DEV_DIR := .dev
SERVER_PID := $(DEV_DIR)/server.pid
SERVER_LOG := $(DEV_DIR)/server.log
API_PORT ?= 8080
API_BASE_URL ?= http://localhost:$(API_PORT)
# 3000 is often taken by bun/Next/etc.; override with: make dev WEB_PORT=3001
WEB_PORT ?= 5080

.PHONY: help up db-up down db-down db-reset db-logs \
	server-deps client-deps migrate server client \
	dev stop stop-api status wait-db ensure-dev-dir check-web-port

help: ## List available targets
	@echo "Budget Tool — make targets"
	@echo ""
	@echo "  make up / db-up     Start Postgres (docker) and wait until healthy"
	@echo "  make down / db-down Stop containers (keeps named volume)"
	@echo "  make db-reset       DESTRUCTIVE: remove volume and recreate db"
	@echo "  make db-logs        Follow Postgres logs"
	@echo "  make server-deps    dart pub get in server/"
	@echo "  make client-deps    flutter pub get in client/"
	@echo "  make migrate        Run server migrations (server/bin/migrate.dart)"
	@echo "  make server         Migrate then start API on :$(API_PORT)"
	@echo "  make client         Flutter web on :$(WEB_PORT)"
	@echo "  make dev            DB + migrate + API (bg) + Flutter (fg)"
	@echo "  make stop           Stop background API + docker compose stop"
	@echo "  make stop-api       Stop background API only"
	@echo "  make status         Show compose + server PID status"
	@echo "  make help           This list"
	@echo ""
	@echo "Persistence: Docker named volume budget_pgdata (survives make down/stop)."
	@echo "API: $(API_BASE_URL)  |  Web: http://localhost:$(WEB_PORT)"
	@echo "Override ports: make dev WEB_PORT=5081 API_PORT=8081"

ensure-dev-dir:
	@mkdir -p $(DEV_DIR)

# Fail fast with a clear fix if the Flutter web port is already bound.
check-web-port:
	@if lsof -nP -iTCP:$(WEB_PORT) -sTCP:LISTEN >/dev/null 2>&1; then \
		echo "ERROR: port $(WEB_PORT) is already in use:"; \
		lsof -nP -iTCP:$(WEB_PORT) -sTCP:LISTEN || true; \
		echo ""; \
		echo "Pick a free port, e.g.:  make dev WEB_PORT=5081"; \
		exit 1; \
	fi

# --- Database ---

up db-up: ## Start Postgres and wait until healthy
	@$(COMPOSE) up -d $(DB_SERVICE)
	@$(MAKE) --no-print-directory wait-db

wait-db:
	@echo "Waiting for Postgres to become healthy..."
	@for i in $$(seq 1 60); do \
		if $(COMPOSE) exec -T $(DB_SERVICE) pg_isready -U budget -d budget >/dev/null 2>&1; then \
			echo "Postgres is healthy."; \
			exit 0; \
		fi; \
		sleep 1; \
	done; \
	echo "ERROR: Postgres did not become healthy in time."; \
	$(COMPOSE) ps; \
	exit 1

down db-down: ## Stop containers (volume kept)
	@$(COMPOSE) down
	@echo "Containers stopped. Named volume budget_pgdata was kept."

db-reset: ## DESTRUCTIVE: wipe Postgres volume and recreate
	@echo "WARNING: This deletes all Postgres data (volume budget_pgdata)."
	@$(COMPOSE) down -v
	@$(MAKE) --no-print-directory up

db-logs: ## Follow Postgres logs
	@$(COMPOSE) logs -f $(DB_SERVICE)

# --- Dependencies ---

server-deps: ## dart pub get (tolerates missing server/)
	@if [ ! -d server ]; then \
		echo "server/ not found yet — skipping dart pub get."; \
		echo "Create the Dart API under server/, then re-run: make server-deps"; \
		exit 0; \
	fi
	@if [ ! -f server/pubspec.yaml ]; then \
		echo "server/pubspec.yaml missing — skipping dart pub get."; \
		exit 0; \
	fi
	@cd server && dart pub get

client-deps: ## flutter pub get (tolerates missing client/)
	@if [ ! -d client ]; then \
		echo "client/ not found yet — skipping flutter pub get."; \
		echo "Create the Flutter app under client/, then re-run: make client-deps"; \
		exit 0; \
	fi
	@if [ ! -f client/pubspec.yaml ]; then \
		echo "client/pubspec.yaml missing — skipping flutter pub get."; \
		exit 0; \
	fi
	@cd client && flutter pub get

# --- Migrations ---
# Expected: server/bin/migrate.dart  (run via: cd server && dart run bin/migrate.dart)
# Also accepts a pubspec script named "migrate" if present.

migrate: ## Run DB migrations if migrate entrypoint exists
	@if [ ! -d server ]; then \
		echo "server/ not found — skipping migrate."; \
		exit 0; \
	fi
	@set -a; [ -f .env ] && . ./.env; set +a; \
	if [ -f server/bin/migrate.dart ]; then \
		echo "Running migrations: dart run bin/migrate.dart"; \
		cd server && dart run bin/migrate.dart; \
	elif grep -qE '^[[:space:]]*migrate:' server/pubspec.yaml 2>/dev/null; then \
		echo "Running migrations: dart run migrate"; \
		cd server && dart run migrate; \
	else \
		echo "No migration entrypoint found."; \
		echo "Expected: server/bin/migrate.dart"; \
		echo "  (run via: cd server && dart run bin/migrate.dart)"; \
		echo "Skipping migrate until the server agent adds it."; \
	fi

# --- App processes ---

server: up server-deps migrate ## Start API in foreground on :8080
	@if [ ! -f server/bin/server.dart ]; then \
		echo "ERROR: server/bin/server.dart not found."; \
		echo "The API agent must create this entrypoint first."; \
		exit 1; \
	fi
	@set -a; [ -f .env ] && . ./.env; set +a; \
		cd server && dart run bin/server.dart

client: client-deps check-web-port ## Start Flutter web (default :5080)
	@if [ ! -f client/pubspec.yaml ]; then \
		echo "ERROR: client/ not ready (missing pubspec.yaml)."; \
		exit 1; \
	fi
	@cd client && flutter run -d chrome --web-port=$(WEB_PORT) \
		--dart-define=API_BASE_URL=$(API_BASE_URL)

dev: ensure-dev-dir up server-deps migrate check-web-port ## DB + API (bg) + Flutter (fg)
	@if [ ! -f server/bin/server.dart ]; then \
		echo "WARNING: server/bin/server.dart not found — API not started."; \
		echo "Continuing without API. Add server/, then: make stop && make dev"; \
	else \
		$(MAKE) --no-print-directory stop-api; \
		set -a; [ -f .env ] && . ./.env; set +a; \
		(cd server && exec dart run bin/server.dart > ../$(SERVER_LOG) 2>&1) & echo $$! > $(SERVER_PID); \
		sleep 1; \
		if kill -0 $$(cat $(SERVER_PID)) 2>/dev/null; then \
			echo "API started in background (PID $$(cat $(SERVER_PID)))."; \
			echo "  logs: $(SERVER_LOG)"; \
			echo "  url:  $(API_BASE_URL)"; \
		else \
			echo "ERROR: API failed to start. See $(SERVER_LOG)"; \
			rm -f $(SERVER_PID); \
			exit 1; \
		fi; \
	fi
	@echo ""
	@echo "Starting Flutter web on http://localhost:$(WEB_PORT) (foreground)."
	@echo "Ctrl+C stops Flutter only. Then: make stop"
	@echo ""
	@if [ ! -f client/pubspec.yaml ]; then \
		echo "client/ not ready yet — Flutter not started."; \
		echo "API (if started) is still running in the background."; \
		echo "When client/ exists: make client   or   make stop && make dev"; \
		exit 0; \
	fi
	@cd client && flutter pub get
	@cd client && flutter run -d chrome --web-port=$(WEB_PORT) \
		--dart-define=API_BASE_URL=$(API_BASE_URL)

stop: stop-api ## Stop background API and docker compose stop (volume kept)
	@if $(COMPOSE) stop 2>/dev/null; then \
		echo "Docker services stopped. Volume budget_pgdata kept."; \
	else \
		echo "WARNING: docker compose stop failed (is Docker running?). Volume kept if present."; \
	fi

stop-api: ## Stop background API (PID file and anything on the API port)
	@if [ -f $(SERVER_PID) ]; then \
		pid=$$(cat $(SERVER_PID)); \
		if kill -0 $$pid 2>/dev/null; then \
			echo "Stopping API (PID $$pid)..."; \
			kill $$pid 2>/dev/null || true; \
			sleep 0.5; \
			if kill -0 $$pid 2>/dev/null; then \
				kill -9 $$pid 2>/dev/null || true; \
			fi; \
			echo "API stopped."; \
		else \
			echo "Stale PID file (process not running)."; \
		fi; \
		rm -f $(SERVER_PID); \
	fi
	@# Also free API port if a dart orphan still holds it
	@if lsof -nP -iTCP:$(API_PORT) -sTCP:LISTEN >/dev/null 2>&1; then \
		echo "Freeing port $(API_PORT)..."; \
		lsof -nP -iTCP:$(API_PORT) -sTCP:LISTEN -t | xargs kill 2>/dev/null || true; \
		for _ in $$(seq 1 50); do \
			lsof -nP -iTCP:$(API_PORT) -sTCP:LISTEN >/dev/null 2>&1 || break; \
			sleep 0.1; \
		done; \
	fi

status: ## Show compose + server status
	@echo "=== docker compose ==="
	@$(COMPOSE) ps 2>/dev/null || echo "(Docker not available or project not started)"
	@echo ""
	@echo "=== API server ==="
	@if [ -f $(SERVER_PID) ]; then \
		pid=$$(cat $(SERVER_PID)); \
		if kill -0 $$pid 2>/dev/null; then \
			echo "Running (PID $$pid) — logs: $(SERVER_LOG)"; \
		else \
			echo "Not running (stale PID $$pid in $(SERVER_PID))"; \
		fi; \
	else \
		echo "Not running (no $(SERVER_PID))"; \
	fi
