# EMSLatencyBudgetSlowBurn

| Severity | SLO | Fires when |
|---|---|---|
| **ticket** | latency (95% of requests < 500 ms, 7 days) | `ems:slo_latency:ratio_rate6h > 0.3` **and** `ems:slo_latency:ratio_rate30m > 0.3`, for 15 min |

## Meaning

More than 30% of requests (6 x the 5% budget) were slower than 500 ms over 6 hours, and still are.
Inhibited while [EMSLatencyBudgetFastBurn](EMSLatencyBudgetFastBurn.md) fires.

## Impact

The application feels sluggish for many users. The latency budget for the week runs out in about a day.

## Diagnosis

1. Which endpoints are slow over the long window:
   ```bash
   promql 'topk(5, histogram_quantile(0.95, sum by (le, endpoint) (rate(ems_http_request_duration_seconds_bucket{job="ems-app",endpoint!="/metrics"}[6h]))))'
   promql 'sum by (endpoint) (rate(ems_http_requests_total{job="ems-app",endpoint!="/metrics"}[6h]))'   # traffic share
   ```
   A slow endpoint with a lot of traffic burns most of the budget.
2. Gradual causes: table growth (`ems_employees_total` over 7 days), missing index, CPU credits draining
   (CloudWatch `CPUCreditBalance` on the `ems-dev` dashboard), memory pressure causing swap/GC.
3. Pick a slow request and read its trace:
   ```bash
   docker logs --since 6h ems-app-1 2>&1 | jq -cR 'fromjson? | select(.duration_ms > 500) | {path, duration_ms, trace_id}' | tail -5
   ```
   `http://127.0.0.1:16686/trace/<trace_id>`: how many SQL spans (N+1 queries?) and which one is long.
4. Query plan for the suspect query:
   ```bash
   docker exec -it ems-db-1 psql -U ems -d ems -c 'EXPLAIN ANALYZE <query from the span>'
   ```

## Mitigation

- Fix forward: index, pagination, fewer queries per request (fix shipped through the normal CI/CD path).
- Capacity: more gunicorn workers (`GUNICORN_WORKERS` in `/opt/ems/.env`), larger instance type in
  `terraform/envs/dev`, or more replicas on Kubernetes.
- If a recent release caused it: roll back (`ansible/playbooks/rollback.yml -e ems_image_tag=<previous-tag>`).

## Escalation

Ticket for the service owner. Page only if it becomes a fast burn.

Related: [EMSLatencyBudgetFastBurn](EMSLatencyBudgetFastBurn.md), [EMSHighLatency](EMSHighLatency.md), [SLOs](../sre/slo.md)
