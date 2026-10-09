# EMSErrorBudgetSlowBurn

| Severity | SLO | Fires when |
|---|---|---|
| **ticket** | availability (99.5% no 5xx, 7 days) | `ems:slo_errors:ratio_rate6h > 0.03` **and** `ems:slo_errors:ratio_rate30m > 0.03`, for 15 min |

## Meaning

More than 3% of requests (6 x the 0.5% budget) failed with a 5xx over 6 hours, and the last 30 minutes agree.
5% of the weekly budget goes every 6 hours; left alone the budget is gone in about a day.
Inhibited while [EMSErrorBudgetFastBurn](EMSErrorBudgetFastBurn.md) fires.

## Impact

A steady trickle of errors: some users, some requests. Not urgent per minute, but it eats the budget that pays
for releases. Handle it the same working day.

## Diagnosis

1. Size and shape:
   ```bash
   promql 'ems:slo_errors:ratio_rate6h'
   promql 'sum by (endpoint, status) (increase(ems_http_requests_total{job="ems-app",status=~"5.."}[6h]))'
   ```
   One endpoint with all the errors = a bug; errors spread evenly = infrastructure (DB, memory, restarts).
2. Budget left this week (Grafana RED "Error budget burn rate", or):
   ```bash
   promql '1 - (sum(increase(ems_http_requests_total{job="ems-app",endpoint!="/metrics",status=~"5.."}[7d])) / sum(increase(ems_http_requests_total{job="ems-app",endpoint!="/metrics"}[7d]))) / 0.005'
   ```
   (`1 - error_ratio_7d / 0.005` = fraction of budget left; negative = SLO already missed.)
3. Intermittent causes to rule out:
   ```bash
   promql 'changes(container_start_time_seconds{name=~"ems-.+"}[6h])'    # restarts
   promql 'min_over_time(ems_db_up[6h])'                                # DB blips
   ```
4. Group the failing requests by error message:
   ```bash
   docker logs --since 6h ems-app-1 2>&1 | jq -rR 'fromjson? | select(.level == "ERROR") | .message' | sort | uniq -c | sort -rn | head
   ```
   Pick a `request_id`, find its `trace_id`, open it in Jaeger.

## Mitigation

- A bug in one endpoint: fix forward with a normal release, or roll back if the last release introduced it
  (`ansible/playbooks/rollback.yml -e ems_image_tag=<previous-tag>`).
- Restarts / memory: see [ContainerRestarting](ContainerRestarting.md), [ContainerHighMemory](ContainerHighMemory.md).
- DB blips: check `docker logs ems-db-1` for connection limits or checkpoints; see [EMSDatabaseDown](EMSDatabaseDown.md).
- Record how much budget was spent; apply the [error-budget policy](../sre/error-budget-policy.md) thresholds.

## Escalation

Ticket to the service owner. Escalate to a page if it turns into a fast burn, or if more than 50% of the weekly
budget is gone.

Related: [EMSErrorBudgetFastBurn](EMSErrorBudgetFastBurn.md), [EMSHighErrorRate](EMSHighErrorRate.md), [SLOs](../sre/slo.md), [error-budget policy](../sre/error-budget-policy.md)
