# ADR 0007: Alert on SLO burn rate, not on raw thresholds

- Status: accepted

## Context
Threshold alerts (CPU > 80 %, one 500) page for things users never notice and miss slow degradations.

## Decision
Two SLOs over 7 days (99.5 % without 5xx, 95 % under 500 ms). Pages come from multi-window burn rates (14.4x over
1 h and 5 m); tickets from slow burns (6x over 6 h and 30 m). Cause-based alerts remain only where they predict an
outage (disk, crash loops, database down). Every alert has a runbook, enforced by tests; `promtool test rules` proves
when each fires.

## Consequences
+ fewer, more meaningful pages; + the error budget gives a rule for release speed (docs/sre/error-budget-policy.md);
- the SLI is measured in the app, so failures in nginx or the ALB are only seen through the ALB alarms.
