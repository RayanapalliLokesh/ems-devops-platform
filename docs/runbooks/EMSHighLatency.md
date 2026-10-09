# EMSHighLatency

| Severity | Fires when |
|---|---|
| **ticket** | p95 of `ems_http_request_duration_seconds` (all endpoints except `/metrics`, 5 min) > 0.5 s for 10 minutes |

## Meaning

The 95th percentile request takes longer than 500 ms. A simple threshold that shows *how slow* (the burn-rate
alerts show *how much budget*). Note `histogram_quantile` interpolates inside buckets (0.25-0.5-1 s), so the
value is an estimate. Inhibited while [EMSAppDown](EMSAppDown.md) fires.

## Impact

Slow pages for at least 1 in 20 requests; the latency SLO budget burns.

## Diagnosis

1. Per endpoint:
   ```bash
   promql 'histogram_quantile(0.95, sum by (le, endpoint) (rate(ems_http_request_duration_seconds_bucket{job="ems-app",endpoint!="/metrics"}[5m])))'
   ```
2. App time vs total time: in the nginx log `duration_s` (total) vs `upstream_s` (app). Both high = the app is
   slow; only `duration_s` high = slow client / network.
   ```bash
   docker logs --since 10m ems-nginx-1 2>&1 | jq -cR 'fromjson? | select(.duration_s > 0.5) | {path, duration_s, upstream_s, request_id}' | tail
   ```
3. Traces: Jaeger, service `ems-app`, Min Duration `500ms`; compare the SQL spans to the request span.
4. Saturation: Grafana USE dashboard (CPU, load vs cores, memory), `docker stats --no-stream`, CloudWatch
   `CPUCreditBalance` (dashboard `ems-dev`).

## Mitigation

- CPU: [HostHighCPU](HostHighCPU.md). Memory/swap: [HostHighMemory](HostHighMemory.md).
- One slow query: ticket a fix (index / pagination); `pg_cancel_backend(<pid>)` for a runaway query.
- Release regression: roll back with `ansible/playbooks/rollback.yml -e ems_image_tag=<previous-tag>`.
- Kubernetes: `kubectl -n ems scale deployment/ems-app --replicas=4`.

## Escalation

Ticket. Becomes a page through [EMSLatencyBudgetFastBurn](EMSLatencyBudgetFastBurn.md).

Related: [EMSLatencyBudgetFastBurn](EMSLatencyBudgetFastBurn.md), [EMSLatencyBudgetSlowBurn](EMSLatencyBudgetSlowBurn.md), [traces](../observability/traces.md)
