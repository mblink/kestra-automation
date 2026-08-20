# Developer task runner -- one place for the common commands. Run `make` (or
# `make help`) to list targets. Mirrors /src/salt/Makefile's conventions.

VENV := .venv
PYTEST := $(shell [ -x $(VENV)/bin/pytest ] && echo $(VENV)/bin/pytest || echo pytest)

.DEFAULT_GOAL := help
.PHONY: help setup test test-integration generate-error-block

help: ## List available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: ## Create the test venv and install requirements-dev.txt (idempotent)
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q -r requirements-dev.txt

test: ## Run the flow YAML test suite (static checks only, no AWS calls)
	$(PYTEST) -v

sync: ## Sync Kestra flows
	sudo bash +x /usr/local/bin/kestra-sync-flows.sh

test-integration: ## Opt-in: run AwsCLI tasks for real against live AWS (needs real credentials; not in CI)
	$(PYTEST) -v -s -m integration

generate-error-block: ## Print the canonical errors: block template (TODO: real per-flow generation + drift check, see SESSION_DEBRIEF.md)
	@echo 'errors:'
	@echo '  - id: notify_failure'
	@echo '    type: io.kestra.plugin.notifications.sendgrid.SendGridMailSend'
	@echo '    sendgridApiKey: "{{ secret('"'"'SENDGRID_API_KEY'"'"') }}"'
	@echo '    from: kestra@bondlink.com'
	@echo '    to:'
	@echo '      - jeff@bondlink.com'
	@echo '    subject: "REPLACE ME"'
	@echo '    htmlContent: |'
	@echo '      Execution {{ execution.id }} of {{ flow.namespace }}.{{ flow.id }} failed.'
	@echo '      Failed task: {{ tasksWithState('"'"'FAILED'"'"')[0].id }}'
