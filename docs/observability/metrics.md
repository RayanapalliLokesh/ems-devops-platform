# Metrics (Phase 24)

The app exposes Prometheus metrics at `GET /metrics` (code: [`app/observability.py`](../../app/observability.py)).
Prometheus scrapes `app:5000` directly on the internal Docker network every 15 s (job `ems-app`); nginx answers
**404** for `/metrics`, so it is never public.

## What the app exposes

| Metric | Type | Labels | Meaning | Used by |
|---|---|---|---|---|
| `ems_http_requests_total` | counter | `method`, `endpoint`, `status` | requests handled, counted in `after_request` | SLI `ems:slo_errors:*`, `ems:requests:rate5m`, RED "Rate", "Responses by status" |
| `ems_http_request_duration_seconds` | histogram (`_bucket`, `_count`, `_sum`) | `method`, `endpoint` | time from `before_request` to `after_request`. Buckets: 0.01, 0.025, 0.05, 0.1, 0.25, **0.5**, 1, 2.5, 5, 10 s | SLI `ems:slo_latency:*` (`le="0.5"`), EMSHighLatency, RED "Duration" |
| `ems_db_up` | gauge (`mostrecent`) | - | 1 when the last `SELECT 1` succeeded (updated by every `/metrics` and `/health` call) | EMSDatabaseDown, RED "Database up" |
| `ems_employees_total` | gauge (`mostrecent`) | - | employees in the database, refreshed on each scrape | RED "Employees" (a business metric) |

Plus, from Prometheus itself: `up{job="ems-app"}` (1 = scrape succeeded) -> EMSAppDown.

Other jobs (see `monitoring/prometheus/prometheus.yml`): `node` (node-exporter: `node_cpu_seconds_total`,
`node_memory_*`, `node_filesystem_*`, `node_load1`, `node_network_*`), `cadvisor` (`container_cpu_usage_seconds_total`,
`container_memory_working_set_bytes`, `container_spec_memory_limit_bytes`, `container_start_time_seconds`, label
`name` = container name), `prometheus`, `alertmanager`.

Recording rules (`monitoring/prometheus/rules/ems-slo.yml`): `ems:requests:rate5m`, and
`ems:slo_errors:ratio_rate{5m,30m,1h,6h}`, `ems:slo_latency:ratio_rate{5m,30m,1h,6h}`. All exclude `/metrics`.
See [docs/sre/slo.md](../sre/slo.md).

## Why `endpoint` is the URL rule, not the path

```python
endpoint = request.url_rule.rule if request.url_rule else 'unmatched'
```

`/api/employees/17` and `/api/employees/18` are both recorded as `endpoint="/api/employees/<int:employee_id>"`.
Every distinct label value creates a new time series (per method, per status, and x 12 for the histogram
buckets). With the raw path, every employee ID, every scanner probing `/wp-login.php` and every typo would create
series forever: **unbounded cardinality**, which grows Prometheus memory until it falls over. With the rule, the
number of series is fixed by the code: (routes + `unmatched`) x methods x statuses. Requests that match no route
(404s from scanners) all share `endpoint="unmatched"`.

The same reasoning keeps `request_id`, user IDs and query strings out of labels: they belong in logs and traces.

## Gunicorn and multiprocess mode

Gunicorn runs `GUNICORN_WORKERS` (default 2) separate **processes**. Each has its own copy of every counter, and a
scrape reaches only one of them, so naive metrics would jump between workers' values. `prometheus_client`
multiprocess mode solves this:

1. The image sets `PROMETHEUS_MULTIPROC_DIR=/tmp/prometheus` (a tmpfs in Compose, an `emptyDir` in Kubernetes).
2. Every worker writes its metric values to memory-mapped files in that directory.
3. `/metrics` builds a fresh `CollectorRegistry` with `MultiProcessCollector`, which sums counters and histograms
   over all files. Gauges need a rule for merging: `ems_db_up` and `ems_employees_total` use `mostrecent`.
4. `gunicorn.conf.py` empties the directory in `on_starting` (stale files from a previous run would add old
   counts) and calls `mark_process_dead(pid)` in `child_exit` (drops the live gauges of a recycled worker;
   workers are recycled every ~1000 requests).

Consequences: the default `process_*` / `python_*` metrics are not exported in multiprocess mode (use cAdvisor
for container CPU/memory), and counters reset when the container restarts, which `rate()` handles.
Without `PROMETHEUS_MULTIPROC_DIR` (tests, `python run.py`) the default registry is used.

## Useful queries

```promql
sum by (endpoint) (rate(ems_http_requests_total{job="ems-app",endpoint!="/metrics"}[5m]))          # traffic
sum by (endpoint) (rate(ems_http_requests_total{job="ems-app",status=~"5.."}[5m]))                  # errors
histogram_quantile(0.95, sum by (le, endpoint) (rate(ems_http_request_duration_seconds_bucket{job="ems-app"}[5m])))  # p95
sum(rate(ems_http_request_duration_seconds_sum[5m])) / sum(rate(ems_http_request_duration_seconds_count[5m]))       # mean
count({__name__=~"ems_.*"})                                                                          # series count (cardinality check)
```

Raw output, from the host: `docker exec ems-prometheus-1 wget -qO- http://app:5000/metrics | grep '^ems_'`.
