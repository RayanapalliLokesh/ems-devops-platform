# Developer shortcuts. Run `make help`.
.PHONY: help venv run test

help:
	@grep -E "^[a-z-]+:.*##" Makefile | sed "s/:.*##/ -/"

venv: ## create the virtual environment and install dev dependencies
	python3 -m venv venv && . venv/bin/activate && pip install -r requirements-dev.txt

run: ## start the development server (SQLite)
	python run.py

test: ## run the unit tests
	FLASK_ENV=testing pytest tests -q
