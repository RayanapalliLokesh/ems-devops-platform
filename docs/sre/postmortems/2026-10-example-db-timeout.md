# Postmortem: database hang makes the app look down (GAME-DAY EXERCISE)

> **This is a game-day exercise, not a real incident.** The failure was injected on purpose on the dev
> environment with `scripts/chaos/db-timeout.sh --inject --mode pause`. It serves as the worked example for
> [postmortem-template.md](../postmortem-template.md). Times and numbers come from the dev environment under a
> synthetic load of ~2 requests/s and are illustrative.

| Field | Value |
|---|---|
| Date | 2026-10-08 |
| Authors | EMS platform owner |
| Status | reviewed |
| Severity | page (EMSAppDown) |
| Duration | 10:05 -> 10:15:40 UTC, ~11 minutes (10 minutes injected) |
| Time to detect / mitigate | 2 min to alert; mitigation = the scheduled revert at +10 min |
| SLO impact | availability: ~1,250 failed requests (502/504 at nginx + 503 at the ALB) = **not visible in the app SLI**; latency: ~40 slow requests recorded after the revert |
| Incident record | game-day session 2026-10, results table in [game-days.md](../game-days.md) |

## Summary

The PostgreSQL container was paused for 10 minutes. Queries did not fail, they hung. The app's request
threads blocked, `/metrics` and `/health` blocked with them, Prometheus' scrapes timed out and **EMSAppDown**
paged after 2 minutes, while **EMSDatabaseDown** was inhibited. The hypothesis expected exactly that alert, but
the investigation showed two weaknesses: the on-call person first restarted the app (wrong cause), and the
availability SLI measured almost nothing of the outage.

## Impact

- All requests through the ALB failed for ~10 minutes: first nginx 504 after its 35 s read timeout, then ALB
  503 once the target was unhealthy (3 health checks x 5 s timeout).
- Hung requests never completed inside Flask, so `ems_http_requests_total` did not count them as errors:
  `ems:slo_errors:ratio_rate5m` stayed at 0. EMSErrorBudgetFastBurn did **not** fire.
- When the database was unpaused, the blocked requests completed with 30-600 s durations and were recorded as
  slow: the latency SLI showed the outage only after it was over.
- No data lost.

## Timeline (UTC)

| Time | Event |
|---|---|
| 10:00 | steady state checked (all green), synthetic load started |
| 10:05:00 | `docker pause ems-db-1` (injection) |
| 10:05:40 | first nginx 504 in `ems-nginx-1` log |
| 10:06:10 | ALB target `unhealthy` (Health checks timed out) |
| 10:07:00 | **EMSAppDown** firing (scrape timeout 10 s, `for: 1m`) |
| 10:07:30 | CloudWatch `ems-dev-alb-unhealthy-hosts` in ALARM |
| 10:08:00 | on-call opens EMSAppDown runbook, sees app container `running`, restarts it (`docker compose -p ems restart app`) |
| 10:09:30 | app restarts but blocks on startup DB access; still down |
| 10:11:00 | on-call runs `wget http://app:5000/livez` (fast) vs `/metrics` (hangs), checks `docker inspect ems-db-1` -> `paused` |
| 10:15:00 | scheduled revert: `docker unpause ems-db-1` |
| 10:15:40 | target healthy, EMSAppDown resolved |

## Root cause and trigger

Trigger: the injected pause. Root cause of the poor experience:

1. **No timeouts towards the database.** `DATABASE_URL` sets no `connect_timeout` and PostgreSQL has no
   `statement_timeout`, so a hanging database turns into hanging requests instead of fast 5xx errors.
2. **`/metrics` depends on the database** (`SELECT 1` for `ems_db_up`). When the DB hangs, the whole scrape
   fails, which hides `ems_db_up` exactly when it matters and makes the problem look like "app down".
3. **The SLI is measured inside the app.** Requests that never finish are invisible to it.

## Detection

The page came in 2 minutes, which is good. It named the wrong component: the runbook at that time did not
mention that a hanging database makes the scrape time out. The CloudWatch alarm confirmed the user impact.

## Response

Restarting the app was harmless but cost 3 minutes. The decisive check (`/livez` fast, `/metrics` slow) was not
in the runbook.

## What went well

- The alert fired quickly and the inhibition prevented a storm of follow-up notifications.
- The revert brought everything back without touching the app.

## What went wrong

- The availability SLO did not register a 10-minute total outage.
- The runbook sent the responder to the app first.

## Where we got lucky

- It was a pause, not disk corruption: unpausing fixed everything.

## Action items

| # | Action | Type | Priority | Owner | Status |
|---|---|---|---|---|---|
| 1 | Add `?connect_timeout=3` to `DATABASE_URL` and `options=-c statement_timeout=5000` so DB hangs become fast 503s | prevent | P1 | platform owner | open |
| 2 | Time-box the `SELECT 1` in `/metrics` (or update `ems_db_up` from a background check) so a scrape never hangs | detect | P1 | platform owner | open |
| 3 | EMSAppDown runbook: add the `/livez` vs `/metrics` check and "db paused/hanging" to the table | mitigate | P1 | platform owner | **done** ([EMSAppDown.md](../../runbooks/EMSAppDown.md)) |
| 4 | Add an ALB-based availability SLI (CloudWatch `HTTPCode_ELB_5XX_Count` + `HTTPCode_Target_5XX_Count` / `RequestCount`) next to the app SLI | detect | P2 | platform owner | open |
| 5 | Repeat the scenario with `--mode stop` and after items 1-2 are done (schedule 2027-02) | process | P3 | platform owner | open |

## Lessons

A failing dependency is easier to handle than a hanging one: put timeouts on every network call. Measure
availability where the user is (the load balancer), not only where the code is.
