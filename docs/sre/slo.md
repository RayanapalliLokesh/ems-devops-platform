# Service Level Objectives (Phase 25)

Two SLOs for the EMS application, both over a **rolling 7-day window** (Prometheus keeps exactly 7 days:
`--storage.tsdb.retention.time=7d`).

| SLO | Objective | SLI (good events / valid events) | Error budget |
|---|---|---|---|
| Availability | **99.5%** of requests answer without a 5xx | requests with `status !~ "5.."` / all requests | 0.5% of the week's requests (`0.005`) |
| Latency | **95%** of requests answer in under **500 ms** | requests in bucket `le="0.5"` / all requests | 5% of the week's requests (`0.05`) |

Valid events: every request the Flask app handled (`job="ems-app"`), **except `/metrics`** (Prometheus' own
scrapes are not user traffic). `/health` is included on purpose: the ALB calls it every 15 s, so an outage
with zero users is still measured.

## SLIs as PromQL

The recording rules in [`monitoring/prometheus/rules/ems-slo.yml`](../../monitoring/prometheus/rules/ems-slo.yml)
compute the *bad* ratio for four windows (5m, 30m, 1h, 6h), named `ems:slo_<slo>:ratio_rate<window>`:

```promql
# availability: share of requests that failed (5m window shown)
ems:slo_errors:ratio_rate5m =
  sum(rate(ems_http_requests_total{job="ems-app",endpoint!="/metrics",status=~"5.."}[5m]))
  /
  sum(rate(ems_http_requests_total{job="ems-app",endpoint!="/metrics"}[5m]))

# latency: share of requests slower than 500 ms
ems:slo_latency:ratio_rate5m =
  1 - (
    sum(rate(ems_http_request_duration_seconds_bucket{job="ems-app",endpoint!="/metrics",le="0.5"}[5m]))
    /
    sum(rate(ems_http_request_duration_seconds_count{job="ems-app",endpoint!="/metrics"}[5m]))
  )
```

SLO compliance over the whole window (ad hoc, not recorded; a 7d range query is expensive):

```promql
1 - sum(increase(ems_http_requests_total{job="ems-app",endpoint!="/metrics",status=~"5.."}[7d]))
  / sum(increase(ems_http_requests_total{job="ems-app",endpoint!="/metrics"}[7d]))                 # >= 0.995 ?

sum(increase(ems_http_request_duration_seconds_bucket{job="ems-app",endpoint!="/metrics",le="0.5"}[7d]))
  / sum(increase(ems_http_request_duration_seconds_count{job="ems-app",endpoint!="/metrics"}[7d])) # >= 0.95 ?
```

Budget remaining = `1 - (bad_ratio_7d / budget)`; 1 = untouched, 0 = spent, negative = SLO missed.

## Why these numbers

- **99.5%, not 99.9%.** One EC2 host, one PostgreSQL container, deploys that restart the app: the platform
  cannot honestly promise more. 0.5% of a week is ~50 minutes of full outage, which covers a bad deploy plus a
  rollback (~10 minutes) several times over, but not a lost day. 99.9% (10 minutes a week) would be spent by a
  single incident and make the budget meaningless.
- **Counted in requests, not minutes.** A request-based SLI weighs busy hours more than quiet ones, which is
  what users feel, and it falls straight out of the counter we already have.
- **500 ms at 95%.** The API does simple CRUD and aggregates over a small table; p95 on the reference host is
  well under 100 ms. 500 ms leaves room for a cold cache and a t3 running on baseline credits, while still
  catching a real regression (a missing index, an N+1 query). 500 ms is also an existing histogram bucket
  boundary (`le="0.5"`), so the SLI is exact instead of interpolated.
- **95%, not 99%, for latency.** The slow tail is dominated by the first request after a deploy and by
  analytics endpoints; a 99% target would page on noise.
- **7 days.** Matches Prometheus retention (no long-term store in this project) and a weekly review rhythm.
  A 28/30-day window is the common choice in larger setups; the burn-rate factors below were chosen for that,
  and the same *fractions of budget* still apply to a 7-day window (see [alerting.md](alerting.md)).

## What is not covered

- Requests that never reach Flask: nginx 502/504 when the app is down, ALB 503 when there is no healthy target.
  These show up in the nginx log, in `up{job="ems-app"} == 0` (EMSAppDown) and in the CloudWatch alarm
  `ems-dev-alb-5xx` / `ems-dev-alb-unhealthy-hosts`; they are not in the SLI. Measuring at the ALB would be
  more accurate (future work: an ALB-based SLI from CloudWatch).
- Correctness (wrong data with a 200). Covered by tests, not by an SLO.

## Review

Every Monday: read the 7-day compliance of both SLOs on the Grafana RED dashboard, note budget spent and its
causes in the learning log, apply the [error-budget policy](error-budget-policy.md). Revisit the targets
after a month of data: an SLO that is always met with 90% budget left is too loose; one that is always missed
is wrong, not the team.

Enforced by `tests/test_sre.py`: the 99.5 and 500 above must match `0.005` and `le="0.5"` in the rules.
