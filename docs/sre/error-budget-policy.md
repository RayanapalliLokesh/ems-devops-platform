# Error budget policy (Phase 25)

**Budget:** 0.5% of the week's requests may fail (availability SLO 99.5%), and 5% may be slower than 500 ms
(latency SLO 95%). Window: rolling 7 days. See [slo.md](slo.md).

Example: 200,000 requests in a week (the ALB health checks alone are ~80,000: every 15 s from each of the two ALB zones) -> **1,000 failed requests** and
10,000 slow requests are allowed.

The budget is there to be spent on change: releases, experiments, game days. The policy says what happens
when it runs low, decided in advance so nobody has to argue about it during an incident.

## Thresholds

| Budget burned (7 days) | State | What happens |
|---|---|---|
| < 50% | normal | Ship as usual. Game days allowed. |
| >= 50% | caution | Releases need a second look at the rollback plan; no game days on the production-like environment; the cause of the spend is written down in the weekly review. |
| >= 75% | restricted | **Feature freeze**: only bug fixes, security patches and reliability work are released. Every release is watched for 30 minutes after deploy. The top budget consumer gets a ticket with an owner. |
| >= 100% (SLO missed) | frozen | **Full release freeze** except fixes for the cause of the spend and security patches. A postmortem is mandatory for the incidents that spent the budget. The freeze lifts when the rolling 7-day window is back under 100% *and* the postmortem action items with priority P1 are done. |

A single incident that spends more than **20% of the budget** needs a postmortem regardless of the totals.

## How to read the current state

```promql
# fraction of the availability budget spent in the last 7 days (1 = 100%)
(sum(increase(ems_http_requests_total{job="ems-app",endpoint!="/metrics",status=~"5.."}[7d]))
 / sum(increase(ems_http_requests_total{job="ems-app",endpoint!="/metrics"}[7d]))) / 0.005

# same for latency
(1 - sum(increase(ems_http_request_duration_seconds_bucket{job="ems-app",endpoint!="/metrics",le="0.5"}[7d]))
     / sum(increase(ems_http_request_duration_seconds_count{job="ems-app",endpoint!="/metrics"}[7d]))) / 0.05
```

The Grafana RED dashboard shows the burn rate (x normal) for 1 hour; the weekly review uses the queries above.

## Exceptions

- **Planned maintenance** announced in advance (e.g. an instance type change) still counts. Plan it to fit
  the budget; that is what the budget is for.
- **Game days** count too, which is the honest way to learn what they cost. Keep them short and run them
  only below 50% burned.
- **Dependency outages** (an AWS region event) count. If they happen often, the SLO is wrong for this
  architecture, and the fix is architecture (multi-AZ hosts), not an exception.
- Misbehaving clients (a script hammering with bad requests that end in 5xx) count: a 5xx means our code
  failed. Fix the code to return a 4xx.

## Who decides

The service owner applies the policy in the weekly review. During a freeze, any release needs a note in the
PR on how it reduces risk. Changing the policy or the SLO targets is a reviewed PR to this file and
`docs/sre/slo.md`, never a silent change to the alert rules.
