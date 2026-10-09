# Alerting flow (Phase 24-25)

```
app /metrics ──scrape 15s──> Prometheus ──rules every 15s──> firing alert ──> Alertmanager ──webhook──> app POST /api/alerts
node-exporter, cAdvisor ─────┘   (ems-slo.yml: recording)                    (group, route,           (stored in table alert_events,
                                  (ems-alerts.yml: 15 alerts)                 inhibit, repeat)          GET /api/alerts = history)
                                                                                                         │
                                                         human <── runbook_url (docs/runbooks/<AlertName>.md)
AWS side, independent of the host: CloudWatch alarms on ALB + EC2 (cloudwatch.md)
```

## 1. Prometheus evaluates

`prometheus.yml`: `evaluation_interval: 15s`, `rule_files: /etc/prometheus/rules/*.yml`. An alert is *pending*
while its expression is true but `for:` has not elapsed, then *firing*. Every alert has:

- `labels.severity`: `page` or `ticket` (routing and urgency, see [docs/sre/oncall.md](../sre/oncall.md))
- `labels.slo` on the burn-rate alerts: `availability` or `latency`
- `annotations.summary`, `description`, `runbook_url`

See them live: `http://127.0.0.1:9090/alerts` (through the tunnel) or `ALERTS{alertstate="firing"}`.

## 2. Alertmanager routes

[`monitoring/alertmanager/alertmanager.yml`](../../monitoring/alertmanager/alertmanager.yml):

| Setting | Value | Effect |
|---|---|---|
| `group_by` | `[alertname, severity]` | one notification per alert type, not per instance |
| `group_wait` | 30s | wait for related alerts before the first notification |
| `group_interval` | 5m | changes to a group are sent at most every 5 minutes |
| `repeat_interval` | 12h (tickets), **1h** for `severity="page"` | reminder while still firing |
| receiver | `ems-webhook` -> `http://app:5000/api/alerts`, `send_resolved: true` | firing and resolved notifications |

### Inhibition (one cause, one notification)

| While this fires | these are suppressed | Why |
|---|---|---|
| `EMSErrorBudgetFastBurn` | `EMSErrorBudgetSlowBurn` | the fast burn says it all |
| `EMSLatencyBudgetFastBurn` | `EMSLatencyBudgetSlowBurn` | same |
| `EMSAppDown` | `EMSHighErrorRate`, `EMSHighLatency`, `EMSNoTraffic`, `EMSDatabaseDown` | no scrape = these are blind or follow from it |

Suppressed alerts still show as firing in Prometheus; only notifications are held back. Check what is
inhibited/silenced at `http://127.0.0.1:9093`.

## 3. The webhook receiver in the app

`POST /api/alerts` ([`app/routes.py`](../../app/routes.py)) accepts the Alertmanager webhook payload
(`{"alerts": [{"status", "labels", "annotations", "startsAt"}, ...]}`), stores one `AlertEvent` row per alert
(alertname, status, severity, summary, runbook_url, starts_at, received_at), logs a WARNING line with the
runbook URL and answers `202 {"received": n}`. Malformed payloads get `400`.

```bash
curl -s "http://$ALB/api/alerts?status=firing&limit=20" | jq '.alerts[] | {alertname, severity, starts_at, runbook_url}'
docker logs --since 1h ems-app-1 2>&1 | jq -cR 'fromjson? | select(.message | startswith("Alert "))'
```

Test the path end to end without breaking anything:

```bash
# fake an alert directly into Alertmanager (on the host)
docker exec ems-alertmanager-1 amtool alert add alertname=EMSTestAlert severity=ticket \
  --annotation=summary="pipeline test" --annotation=runbook_url=docs/runbooks/README.md \
  --alertmanager.url=http://localhost:9093
# ~30 s later (group_wait) it appears in GET /api/alerts
```

Why a webhook into the app? It needs no external account and proves the whole chain. For real on-call add a
receiver (Slack, e-mail, PagerDuty) next to `ems-webhook` and route `severity="page"` to it.

## 4. A human follows the runbook

Each notification carries `runbook_url`. `tests/test_sre.py` guarantees the file exists and has Meaning,
Diagnosis and Mitigation sections, and `promtool test rules` guarantees the alert fires when it should
([docs/sre/alerting.md](../sre/alerting.md)).

## Blind spots and the safety net

If the EC2 host dies, Prometheus and Alertmanager die with it and nothing above fires. The CloudWatch alarms
(`ems-dev-alb-unhealthy-hosts`, `ems-dev-host-status-check`, ...) run in AWS and cover that case; see
[cloudwatch.md](cloudwatch.md). `MonitoringTargetDown` covers partial monitoring failures.
