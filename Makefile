# Convenience Makefile for local development
# Usage: make up | make down | make build | make logs SERVICE=orchestrator | make tests | make psql | make redis CMD="PING"

SHELL := /bin/sh
SERVICE ?= orchestrator
CMD ?=

.PHONY: help up down downv build rebuild ps logs config tests recreate logsf psql redis health rovo-login rovo-register rovo-deploy rovo-start rovo-stop rovo-status

help:
	@echo "Targets:"
	@echo "  make up            - docker compose up -d"
	@echo "  make down          - docker compose down"
	@echo "  make downv         - docker compose down -v (remove volumes, dev only)"
	@echo "  make build         - docker compose build"
	@echo "  make rebuild       - docker compose build --no-cache"
	@echo "  make ps            - docker compose ps"
	@echo "  make config        - docker compose config (validate)"
	@echo "  make logs          - docker compose logs -f $(SERVICE) (override SERVICE=...)"
	@echo "  make logsf         - alias for logs"
	@echo "  make recreate      - docker compose up -d --force-recreate $(SERVICE)"
	@echo "  make tests         - docker compose run --rm tests"
	@echo "  make psql          - open psql shell to Postgres (reads secrets/postgres_password)"
	@echo "  make redis         - run redis-cli inside redis container (CMD=...)"
	@echo "  make health        - run local health checks for all services (requires ports exposed via override)"
	@echo "  make rovo-login    - rovo-dev login (requires ROVO_EMAIL and ROVO_API_KEY in env)"
	@echo "  make rovo-register - register all agents with rovo-dev"
	@echo "  make rovo-deploy   - deploy all agents via rovo-dev"
	@echo "  make rovo-start    - start all agents via rovo-dev"
	@echo "  make rovo-stop     - stop all agents via rovo-dev"
	@echo "  make rovo-status   - show agent status via rovo-dev"

up:
	docker compose up -d
	docker compose ps
	docker compose config >/dev/null || true
	docker compose run --rm --no-TTY --entrypoint true tests 2>/dev/null || true
	echo "Done. Try: curl -s http://localhost:7001/health | jq ."

build:
	docker compose build

rebuild:
	docker compose build --no-cache

ps:
	docker compose ps

config:
	docker compose config

logs:
	docker compose logs -f $(SERVICE)

logsf: logs

recreate:
	docker compose up -d --force-recreate $(SERVICE)

down:
	docker compose down

# Dev only: removes volumes

downv:
	docker compose down -v

tests:
	docker compose run --rm tests

psql:
	PGPASSWORD=$$(cat secrets/postgres_password 2>/dev/null) \
	docker compose exec -e PGPASSWORD=$$(cat secrets/postgres_password 2>/dev/null) postgres \
	  psql -U $${POSTGRES_USER:-trader} -d $${POSTGRES_DB:-trading}

redis:
	docker compose exec redis redis-cli $(CMD)

health:
	npm run health:check

rovo-login:
	bash scripts/rovo_dev_hooks.sh login

rovo-register:
	bash scripts/rovo_dev_hooks.sh register-agents

rovo-deploy:
	bash scripts/rovo_dev_hooks.sh deploy-agents

rovo-start:
	bash scripts/rovo_dev_hooks.sh start-agents

rovo-stop:
	bash scripts/rovo_dev_hooks.sh stop-agents

rovo-status:
	bash scripts/rovo_dev_hooks.sh status
