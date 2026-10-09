# EMSLatencyBudgetFastBurn

| Severity | SLO | Fires when |
|---|---|---|
| **page** | latency (95% of requests < 500 ms, 7 days) | `ems:slo_latency:ratio_rate1h > 0.72` **and** `ems:slo_latency:ratio_rate5m > 0.72`, for 2 min |

## Meaning

More than 72% of requests (14.4 x the 5% latency budget) took longer than 500 ms over the last hour, and still
do. The SLI counts a request as slow when it lands above the `le="0.5"` bucket of
`ems_http_request_duration_seconds`.

## Impact

The application is effectively unusable: most clicks take more than half a second, many far longer. Requests
beyond gunicorn's 30 s timeout become 502/504 at nginx and are not in the app metrics at all, so the real user
pain can be worse than the SLI shows.

## Diagnosis

1. Feel it from outside:
   ```bash
   for i in $(seq 10); do curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://$ALB/api/employees; done
   ```
2. Which endpoint, and how slow (Grafana RED "Duration: p50 / p95 / p99"):
   ```bash
   promql 'histogram_quantile(0.95, sum by (le, endpoint) (rate(ems_http_request_duration_seconds_bucket{job="ems-app"}[5m])))'
   ```
3. Is it the database? Slow `/health` (it only runs `SELECT 1`) = DB or host; fast `/health` but slow API = queries.
   In Jaeger search service `ems-app`, Min Duration `500ms`: long SQL spans point at the query, a long request
   span with short SQL spans points at the app or CPU.
4. Saturation (Grafana USE dashboard):
   ```bash
   promql '100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))'
   promql 'sum by (name) (rate(container_cpu_usage_seconds_total{name=~"ems-.+"}[5m]))'
   ssh ec2-user@$HOST 'docker stats --no-stream'
   ```
   On a t3 instance also check `CPUCreditBalance` on the CloudWatch dashboard `ems-dev`: at 0 the CPU is throttled.
5. Slowest requests in the log:
   ```bash
   docker logs --since 15m ems-app-1 2>&1 | jq -cR 'fromjson? | select(.duration_ms > 500) | {path, duration_ms, request_id, trace_id}' | tail
   ```

## Mitigation

| Cause | Action |
|---|---|
| Last release (new slow query / code) | roll back: `ansible/playbooks/rollback.yml -e ems_image_tag=<previous-tag>` |
| CPU saturation / credits exhausted | [HostHighCPU](HostHighCPU.md): stop the CPU hog; if credits are exhausted, move to a bigger type via `instance_type` in Terraform (unlimited credits are not allowed in the playground account) |
| Too few workers | raise `GUNICORN_WORKERS` in `/opt/ems/.env`, `docker compose -p ems up -d app` (each worker ~100 MB, limit 512m) |
| Database slow / locked | `docker exec ems-db-1 psql -U ems -d ems -c "select pid, state, now()-query_start as age, left(query,80) from pg_stat_activity order by age desc nulls last"`; cancel a runaway query with `select pg_cancel_backend(<pid>)` |
| Kubernetes | `kubectl -n ems scale deployment/ems-app --replicas=4` (the HPA allows 2-4), or `rollout undo` |

## Escalation

Not better within 30 minutes: escalate to the owner, open an incident. Postmortem required.

Related: [EMSLatencyBudgetSlowBurn](EMSLatencyBudgetSlowBurn.md) (inhibited while this fires), [EMSHighLatency](EMSHighLatency.md), [HostHighCPU](HostHighCPU.md), [SLOs](../sre/slo.md)
