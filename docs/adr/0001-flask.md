# ADR 0001: Flask instead of FastAPI

- Status: accepted

## Context
The project grew from a Python training course whose first phases already used Flask.

## Decision
Keep Flask, the application factory and blueprints for every phase.

## Consequences
+ one coherent codebase and history; - no automatic OpenAPI documentation.
