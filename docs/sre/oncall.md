# On-call (Phase 25)

A one-person project still needs the rules written down: they decide what wakes you up and what waits.

## Severities

| Severity | Label | Meaning | Acknowledge | Start mitigating | Notification |
|---|---|---|---|---|---|
| **page** | `severity: page` | Users are affected now, or will be within hours (budget fast burn, app/DB down, disk almost full, crash loop) | 5 min (working hours) / 15 min (on call out of hours) | immediately after acknowledging | Alertmanager webhook, repeated every 1 h while firing |
| **ticket** | `severity: ticket` | Something degrades or a guard is blind; no immediate user impact | next working day | within 2 working days | webhook, repeated every 12 h |

Pages today: EMSErrorBudgetFastBurn, EMSLatencyBudgetFastBurn, EMSAppDown, EMSDatabaseDown, HostDiskSpaceLow,
ContainerRestarting. Everything else is a ticket. The full list with runbooks: [docs/runbooks/README.md](../runbooks/README.md).

CloudWatch alarms (`ems-dev-alb-5xx`, `ems-dev-alb-unhealthy-hosts`, `ems-dev-host-cpu-high`,
`ems-dev-host-status-check`) are the safety net when the host, and with it Prometheus, is down. Treat
`unhealthy-hosts` and `status-check` as pages.

## Where alerts arrive

Alertmanager -> `POST http://app:5000/api/alerts` (history: `curl -s http://$ALB/api/alerts?status=firing | jq`).
For a real rotation add a receiver for the paging tool (PagerDuty, Opsgenie, Slack + phone) to
`monitoring/alertmanager/alertmanager.yml` under the `severity="page"` route; tickets go to a channel/issue tracker.

## When a page arrives

1. **Acknowledge** (say "I'm on it" in the incident channel / issue), note the time.
2. Open the **runbook** from the alert's `runbook_url`. Follow Diagnosis -> Mitigation.
3. **Mitigate first, debug later**: rolling back is cheaper than understanding. Rollback:
   `ansible/playbooks/rollback.yml -e ems_image_tag=<previous-tag>` or the `rollback.yml` workflow.
4. If it lasts more than 30 minutes or needs someone else: open an incident from [incident-template.md](incident-template.md).
5. After resolution: postmortem from [postmortem-template.md](postmortem-template.md) within 5 working days for
   every page that spent budget or was not handled by the runbook.

## Silences

Allowed only with an end time and a reason (Alertmanager UI `http://127.0.0.1:9093` through the tunnel, or
`amtool silence add alertname=EMSNoTraffic --duration=2h --comment="dev env stopped overnight"`). Silencing a
page to sleep is not allowed; fixing the alert so it stops being noisy is.

## Hand-over

At the end of an on-call week: open tickets, active silences, budget spent, runbooks that were wrong (fix them
in the same week). An alert that paged without needing action twice in a month gets reviewed: change the
threshold, make it a ticket, or delete it.
