# Grafana dashboards (Phase 24)

Provisioned from files: `monitoring/grafana/provisioning/` (data sources Prometheus + Jaeger, dashboard provider)
and `monitoring/grafana/dashboards/*.json`. Edits in the UI are lost on restart; change the JSON in the repo.
Open: `ssh -L 3000:127.0.0.1:3000 ec2-user@$HOST`, then `http://localhost:3000` (user `admin`, password
`GRAFANA_ADMIN_PASSWORD` from `/opt/ems/.env`).

Two methods, two dashboards:

- **RED** (Rate, Errors, Duration) for the *service*: what users experience.
- **USE** (Utilisation, Saturation, Errors) for the *resources*: why it happens.

Start at RED; if it is red, go to USE to find the resource.

## EMS - RED (rate, errors, duration) - `ems-red.json`

| Panel | Query | Read it as |
|---|---|---|
| Availability SLI (5m) | `1 - ems:slo_errors:ratio_rate5m` | should stay >= 99.5% |
| Requests faster than 500 ms (5m) | `1 - ems:slo_latency:ratio_rate5m` | should stay >= 95% |
| Database up | `ems_db_up` | 1 / 0 (EMSDatabaseDown) |
| Employees | `ems_employees_total` | business sanity check: a sudden drop to 0 = wrong DB / restore |
| Rate: requests per second by endpoint | `sum by (endpoint) (rate(ems_http_requests_total{job="ems-app",endpoint!="/metrics"}[5m]))` | traffic mix; flat zero = EMSNoTraffic |
| Errors: 5xx ratio | `ems:slo_errors:ratio_rate5m`, `ems:slo_errors:ratio_rate1h`, `vector(0.005)` | the 5m and 1h ratios against the 0.5% budget line |
| Duration: p50 / p95 / p99 | `histogram_quantile(0.5/0.95/0.99, sum by (le) (rate(ems_http_request_duration_seconds_bucket{job="ems-app",endpoint!="/metrics"}[5m])))` | p95 above 500 ms = EMSHighLatency |
| Error budget burn rate (1h, x normal) | `ems:slo_errors:ratio_rate1h / 0.005`, `ems:slo_latency:ratio_rate1h / 0.05`, `vector(14.4)`, `vector(6)` | 1 = spending exactly on budget; crossing 6 / 14.4 = slow / fast burn thresholds |
| Responses by status | `sum by (status) (rate(ems_http_requests_total{job="ems-app",endpoint!="/metrics"}[5m]))` | 4xx growth = clients/bad input; 5xx = us |

## EMS - USE (host and containers) - `ems-use.json`

| Panel | Query | U / S / E | Read it as |
|---|---|---|---|
| Host CPU utilisation | `100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))` | U | > 85% for 10m = HostHighCPU; on t3 check credits in CloudWatch |
| Host load (saturation) | `node_load1` vs `count(node_cpu_seconds_total{mode="idle"})` | S | load above the core count = work is queueing |
| Host memory used | `100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)` | U | > 90% = HostHighMemory |
| Disk free on / | `100 * node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}` | U | < 15% = HostDiskSpaceLow (page) |
| Container CPU | `sum by (name) (rate(container_cpu_usage_seconds_total{name=~"ems-.+"}[5m]))` | U | cores used per container: who is busy |
| Container memory (working set) | `container_memory_working_set_bytes{name=~"ems-.+"}` | U/S | compare with `mem_limit`; near the limit = ContainerHighMemory |
| Network errors | `rate(node_network_receive_errs_total[5m]) + rate(node_network_transmit_errs_total[5m])` | E | should be 0 |

## Workflow during an alert

1. RED: which SLI moved, when, which endpoint (Rate, Responses by status)?
2. Correlate the start time with a deploy (container start in USE / `docker inspect`).
3. USE: is a resource saturated at the same time?
4. Jump to logs and traces for one example request ([logs.md](logs.md), [traces.md](traces.md)); Grafana's
   Explore view can query the Jaeger data source by trace ID.

## Kubernetes

`scripts/k8s/k8s-monitoring.sh` loads the same JSON files into the `grafana-dashboards` ConfigMap in namespace
`monitoring`, so both environments show identical dashboards.
