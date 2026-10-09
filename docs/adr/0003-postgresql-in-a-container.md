# ADR 0003: PostgreSQL in a container on the host, not RDS

- Status: accepted

## Context
Phase 12 moved from SQLite to PostgreSQL; Phase 17 packaged everything as containers. The playground allows RDS,
but a session lasts a few hours and RDS takes 10+ minutes to create and to delete, and its backups are not portable
to kind or a laptop.

## Decision
PostgreSQL 16 runs as the `db` service of the Compose stack (a StatefulSet on Kubernetes) on a named volume. Backups
are `pg_dump` files: nightly by a systemd timer, kept 7 days on disk and 30 days in S3 (`backups/` prefix).

## Consequences
+ the same stack runs on a laptop, in CI, on EC2 and on kind; + restore is one command (`backup-db.sh --restore`);
- the host is a single point of failure for the data (RPO up to 24 h); prod would use RDS Multi-AZ (see docs/aws/ha-decisions.md).
