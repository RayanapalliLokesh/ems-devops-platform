# Alerting on the SLOs: multi-window burn rates (Phase 25)

Rules: [`monitoring/prometheus/rules/ems-alerts.yml`](../../monitoring/prometheus/rules/ems-alerts.yml) (group
`ems-slo-burn`), built on the recording rules in `ems-slo.yml`. Tests: `monitoring/prometheus/tests/ems-alerts-test.yml`.

## Burn rate

**Burn rate** = observed bad ratio / budget ratio. Burn rate 1 spends exactly the whole budget in the SLO
window; burn rate 14.4 spends it 14.4 times faster.

```
budget spent = burn rate x (alert window / SLO window)
```

The factors 14.4 and 6 come from the Google SRE workbook, which defines them for a 30-day window:

| Alert | Burn rate | Long window | Budget spent in the long window (30 d SLO) | Short window | `for` | Severity |
|---|---|---|---|---|---|---|
| EMSErrorBudgetFastBurn / EMSLatencyBudgetFastBurn | 14.4x | 1h | 14.4 x 1h / 720h = **2%** | 5m | 2m | **page** |
| EMSErrorBudgetSlowBurn / EMSLatencyBudgetSlowBurn | 6x | 6h | 6 x 6h / 720h = **5%** | 30m | 15m | **ticket** |

Thresholds actually used:

| SLO | Budget | Fast burn (14.4x) | Slow burn (6x) |
|---|---|---|---|
| Availability | 0.005 | bad ratio > **0.072** | bad ratio > **0.03** |
| Latency | 0.05 | bad ratio > **0.72** | bad ratio > **0.3** |

**With our 7-day window** (168 h) the same burn rates spend more of the budget per hour: a 14.4x burn for 1 h
is 14.4/168 = 8.6% of the weekly budget, and the whole budget lasts 168/14.4 = 11.7 h; a 6x burn for 6 h is
21%, the whole budget lasts 28 h. The alert summaries keep the workbook's "2% in 1 hour / 5% in 6 hours"
wording for the rates themselves. The practical meaning is the same: a fast burn exhausts the budget within
a working day (page now), a slow burn within about one day (deal with it today).

## Why two windows per alert

One window alone fails in one of two ways:

- **Only the long window (1h):** after the problem is fixed, the 1h ratio stays above the threshold for up to
  an hour; the alert keeps firing (and re-paging) for a problem that no longer exists. It also needs a long
  time to fire for a sudden total outage.
- **Only the short window (5m):** a 3-minute spike of errors (one bad deploy step, a DB restart) pages
  someone even though it spent a tiny fraction of the budget.

`long > threshold and short > threshold` fires only when the burn is **significant** (the long window says
enough budget is gone) **and still happening** (the short window agrees). It resets within ~5 minutes of the
fix because the short window drops first. The short window is 1/12 of the long one, as in the workbook.

The `for:` (2m / 15m) adds a little noise protection against single bad scrapes.

## Why there are also plain threshold alerts

`EMSHighErrorRate` (> 5% for 5m) and `EMSHighLatency` (p95 > 500 ms for 10m) are tickets that describe the
symptom directly and catch short bursts the burn-rate alerts deliberately ignore. They never page: the
paging decision belongs to the budget.

## Severity and routing

- `severity: page` - someone must act now: SLO fast burns, app down, DB down, disk almost full, crash loop.
- `severity: ticket` - next working day: slow burns, thresholds, resource warnings, monitoring gaps.

Alertmanager ([`alertmanager.yml`](../../monitoring/alertmanager/alertmanager.yml)) groups by `alertname,
severity`, repeats pages every hour and tickets every 12 hours, and **inhibits**: a fast burn silences the
matching slow burn, and `EMSAppDown` silences `EMSHighErrorRate`, `EMSHighLatency`, `EMSNoTraffic` and
`EMSDatabaseDown` (one root cause, one notification). Details: [alerting-flow.md](../observability/alerting-flow.md).

## Testing the rules: `promtool test rules`

`monitoring/prometheus/tests/ems-alerts-test.yml` feeds synthetic series into the real rule files and asserts
which alerts fire at a given time, with which labels and annotations:

| Case | Input | Expected |
|---|---|---|
| fast burn | 10% errors for 2 h | `EMSErrorBudgetFastBurn` (page) and `EMSHighErrorRate` firing at 70m |
| inside budget | 0.1% errors for 6 h | no fast burn, no slow burn |
| short spike | 50% errors for 5 minutes only | no fast burn at 64m or 75m (the 1h window disagrees) |
| app / db down | `up` and `ems_db_up` drop to 0 | `EMSAppDown`, `EMSDatabaseDown` |

Run it (`tests/test_sre.py` runs the same command, and skips it when Docker is missing):

```bash
docker run --rm -v "$PWD/monitoring/prometheus:/p:ro" -w /p/tests --entrypoint promtool \
  prom/prometheus:v2.55.1 test rules ems-alerts-test.yml
```

Every new alert gets at least one "fires" and one "stays silent" case. `tests/test_sre.py` also checks that each
alert has `severity` in {page, ticket} and a `runbook_url` to an existing runbook.
