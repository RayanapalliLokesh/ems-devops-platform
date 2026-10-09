# Developer shortcuts. Run `make help`.
.PHONY: help venv run test lint check up down monitoring logs promtool kind tf-check

ENV_FILE ?= .env.local
COMPOSE  = docker compose --env-file $(ENV_FILE)
COMPOSE_MON = $(COMPOSE) -f docker-compose.yml -f docker-compose.monitoring.yml

help:
	@grep -E "^[a-z-]+:.*##" Makefile | sed "s/:.*##/ -/"

venv: ## create the virtual environment and install dev dependencies
	python3 -m venv venv && . venv/bin/activate && pip install -r requirements-dev.txt

run: ## start the development server (SQLite)
	python run.py

test: ## run all tests (application, platform files, scripts, SLO rules)
	FLASK_ENV=testing pytest tests -q

lint: ## flake8, yamllint, shellcheck, ansible-lint
	flake8
	yamllint .
	find . -name '*.sh' -not -path './venv/*' -print0 | xargs -0 shellcheck
	cd ansible && ansible-lint --offline

tf-check: ## terraform fmt + playground policy check
	terraform fmt -check -recursive terraform
	python3 terraform/tf_static_check.py

check: lint tf-check test ## everything CI runs that works offline

$(ENV_FILE):
	@printf 'POSTGRES_PASSWORD=%s\nSECRET_KEY=%s\nGRAFANA_ADMIN_PASSWORD=%s\nEMS_HTTP_PORT=8080\n' \
	  "$$(openssl rand -hex 16)" "$$(openssl rand -hex 32)" "$$(openssl rand -hex 12)" > $(ENV_FILE)
	@echo "created $(ENV_FILE) with random secrets"

up: $(ENV_FILE) ## build and start the stack: http://localhost:8080
	$(COMPOSE) up -d --build --wait

monitoring: $(ENV_FILE) ## stack + Prometheus :9090, Alertmanager :9093, Grafana :3000, Jaeger :16686
	$(COMPOSE_MON) up -d --build --wait

logs: ## follow the app log
	$(COMPOSE) logs -f app

down: ## stop everything (volumes are kept)
	$(COMPOSE_MON) down

promtool: ## unit-test the alert rules
	docker run --rm -v "$$PWD/monitoring/prometheus:/p:ro" -w /p/tests --entrypoint promtool \
	  prom/prometheus:v2.55.1 test rules ems-alerts-test.yml

kind: ## run the app on a local kind cluster: http://localhost:8081
	scripts/k8s/k8s-up.sh
