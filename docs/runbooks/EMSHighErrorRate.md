# EMSHighErrorRate

| Severity | Fires when |
|---|---|
| **ticket** | `ems:slo_errors:ratio_rate5m > 0.05` and `ems:requests:rate5m > 0.1` for 5 minutes |

## Meaning

More than 5% of requests failed with a 5xx over 5 minutes, with at least some traffic (0.1 req/s, so a single
failed request at night does not fire it). It is a simple threshold, not a burn rate: it catches short error
bursts that the burn-rate alerts deliberately ignore. Inhibited while [EMSAppDown](EMSAppDown.md) fires.

## Impact

Users hit errors now. If it lasts, the burn-rate alerts follow and it becomes a page.

## Diagnosis

1. Where:
   ```bash
   promql 'sum by (endpoint, method, status) (rate(ems_http_requests_total{job="ems-app",status=~"5.."}[5m]))'
   ```
2. Why, from the log (the exception is in the error line of the same request):
   ```bash
   docker logs --since 10m ems-app-1 2>&1 | jq -cR 'fromjson? | select(.status >= 500) | {ts, method, path, request_id, trace_id}' | tail -5
   RID=<request_id>
   docker logs --since 10m ems-app-1 2>&1 | jq -cR --arg r "$RID" 'fromjson? | select(.request_id == $r)'
   docker logs --since 10m ems-nginx-1 2>&1 | jq -cR --arg r "$RID" 'fromjson? | select(.request_id == $r)'
   ```
   Then `http://127.0.0.1:16686/trace/<trace_id>` for the failing span.
3. Reproduce with the same request through the ALB: `curl -si http://$ALB/<path> | head -20` (note the `X-Request-ID`).
4. Correlate with a deploy: `docker inspect ems-app-1 --format '{{.Config.Image}} {{.State.StartedAt}}'`.

## Mitigation

- Started with a release: roll back (`ansible/playbooks/rollback.yml -e ems_image_tag=<previous-tag>` or the `rollback.yml` workflow).
- One bad input path (e.g. a 500 on bad data that should be a 400): ticket a fix; it is a bug, not an outage.
- DB-related errors: [EMSDatabaseDown](EMSDatabaseDown.md).

## Escalation

Ticket. Becomes a page through [EMSErrorBudgetFastBurn](EMSErrorBudgetFastBurn.md) if it continues.

Related: [EMSErrorBudgetFastBurn](EMSErrorBudgetFastBurn.md), [EMSErrorBudgetSlowBurn](EMSErrorBudgetSlowBurn.md), [logs](../observability/logs.md)
