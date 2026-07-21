# Marveen Docker runtime -- operator commands.
#
# Thin-runtime model: the image is just the runtime; Marveen's code + state live
# on the host, bind-mounted at /app (see docs/DOCKER.md). These targets wrap the
# common docker compose flows so you don't memorise the flags.
#
# Override config on the CLI, e.g.:  make up MARVEEN_PORT=3421
#   MARVEEN_HOST_DIR  host path of the repo to mount (default: this dir)
#   MARVEEN_PORT      published dashboard port (default: 3420)
#   PROJECT           compose project name -- set a unique one per instance when
#                     running several Marveens on one host (keeps volumes apart)

COMPOSE      ?= docker compose
MARVEEN_PORT ?= 3420
SERVICE      := marveen
ifdef PROJECT
COMPOSE := $(COMPOSE) -p $(PROJECT)
endif

.DEFAULT_GOAL := help

## ---- lifecycle -------------------------------------------------------------

.PHONY: install
install: ## First-time setup from scratch: seed .env, check token, build + start
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo ">> Created .env from .env.example."; \
		echo ">> Edit it (channel token, MAIN_AGENT_ID, WEB_PORT), then re-run 'make install'."; \
		exit 1; \
	fi
	@if [ ! -s store/.claude-oauth-token ]; then \
		echo ">> store/.claude-oauth-token is missing."; \
		echo ">> Generate it anywhere with a browser:  claude setup-token"; \
		echo ">> Then:  make token   (paste the sk-ant-oat01-... token, Ctrl-D)"; \
		exit 1; \
	fi
	$(COMPOSE) up -d --build
	@$(MAKE) --no-print-directory health

.PHONY: up start
up: ## Start (already installed) -- no build
	$(COMPOSE) up -d
start: up ## Alias for 'up'

.PHONY: down stop
down: ## Stop + remove the container (state on the host is kept)
	$(COMPOSE) down
stop: down ## Alias for 'down'

.PHONY: restart
restart: ## Restart the container (picks up host code changes; entrypoint rebuilds deps/dist if needed)
	$(COMPOSE) restart

.PHONY: update
update: ## Pull latest code on the host + rebuild + restart
	git pull --ff-only
	$(COMPOSE) up -d --build
	@$(MAKE) --no-print-directory health

## ---- build / images --------------------------------------------------------

.PHONY: build
build: ## Build the runtime image
	$(COMPOSE) build

.PHONY: rebuild
rebuild: ## Full image rebuild from scratch (new Node / new Claude CLI)
	$(COMPOSE) build --no-cache
	$(COMPOSE) up -d

## ---- inspect / operate -----------------------------------------------------

.PHONY: logs
logs: ## Follow container logs
	$(COMPOSE) logs -f --tail=100

.PHONY: ps status
ps: ## Show container status
	$(COMPOSE) ps
status: ps ## Alias for 'ps'

.PHONY: shell
shell: ## Open a shell inside the running container
	$(COMPOSE) exec $(SERVICE) bash

.PHONY: health
health: ## Check the dashboard responds on MARVEEN_PORT
	@curl -fsS -o /dev/null -w "dashboard: HTTP %{http_code}\n" http://localhost:$(MARVEEN_PORT)/ \
		|| echo "dashboard: not responding yet (give it a few seconds after 'up')"

.PHONY: token
token: ## Install the OAuth setup-token into store/ (paste it, then Ctrl-D)
	@install -m 600 /dev/stdin store/.claude-oauth-token && echo "token saved to store/.claude-oauth-token (0600)"

## ---- maintenance -----------------------------------------------------------

.PHONY: clean
clean: ## Stop + drop the rebuildable node_modules volume (host state is kept)
	$(COMPOSE) down -v

.PHONY: fix-bindings
fix-bindings: ## Fix better-sqlite3 "bindings file" error: drop node_modules volume + rebuild
	$(COMPOSE) down -v
	$(COMPOSE) up -d --build
	@$(MAKE) --no-print-directory health

## ---- help ------------------------------------------------------------------

.PHONY: help
help: ## Show this help
	@echo "Marveen Docker runtime -- make targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
