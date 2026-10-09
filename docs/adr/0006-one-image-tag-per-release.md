# ADR 0006: A release is one immutable image tag, built once

- Status: accepted (replaces release folders and a symlink from Phase 12)

## Context
Rebuilding for each environment produces different bytes for the same version; a mutable tag such as `latest`
makes "what is running?" unanswerable and rollbacks unreliable.

## Decision
CD builds the image once for a `vX.Y.Z` tag and pushes it to ghcr.io; the same manifest is copied to ECR
(`imagetools create`, same digest). ECR tags are IMMUTABLE. The host records the running tag in `/opt/ems/RELEASE`;
a deploy whose health check fails restores the previous tag automatically. Rollback = deploying an older tag.

## Consequences
+ rollback needs no build and takes about a minute; + `/health` reports the version, so the smoke test proves which
release answers; - a broken tag cannot be fixed in place, only replaced by a new version.
