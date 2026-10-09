# EMSErrorBudgetFastBurn

| Severity | SLO | Fires when |
|---|---|---|
| **page** | availability (99.5% no 5xx, 7 days) | `ems:slo_errors:ratio_rate1h > 0.072` **and** `ems:slo_errors:ratio_rate5m > 0.072`, for 2 min |

## Meaning

More than 7.2% of requests (14.4 x the 0.5% budget) answered with a 5xx over the last hour, and it is still
happening (the 5-minute window agrees). At this rate 2% of the whole weekly error budget is gone every hour;
the full budget lasts about 12 hours.

## Impact

Users see errors on a meaningful share of requests right now. If it continues for a working day, the weekly
availability SLO is lost and the [error-budget policy](../sre/error-budget-policy.md) freezes releases.

## Diagnosis

1. Is it real? From outside, through the ALB:
   ```bash
   for i in $(seq 20); do curl -s -o /dev/null -w '%{http_code}\n' http://$ALB/api/employees; done | sort | uniq -c
   curl -s http://$ALB/health | jq                       # status, database, version
   ```
2. Which endpoints and statuses (Grafana RED dashboard "Responses by status", or):
   ```bash
   promql 'sum by (endpoint, status) (rate(ems_http_requests_total{job="ems-app",status=~"5.."}[5m]))'
   ```
   Only `/health` failing = the database (go to [EMSDatabaseDown](EMSDatabaseDown.md)). All endpoints = app or DB.
   One endpoint = a code path: probably the last release.
3. Did a deploy just happen?
   ```bash
   ssh ec2-user@$HOST 'docker inspect ems-app-1 --format "{{.Config.Image}} started {{.State.StartedAt}}"'
   ```
   Compare with the start of the burn on the "Errors: 5xx ratio" panel.
4. Read the failing requests and their exceptions:
   ```bash
   docker logs --since 15m ems-app-1 2>&1 | jq -cR 'fromjson? | select(.status >= 500) | {ts, request_id, path, status, trace_id}' | tail
   docker logs --since 15m ems-app-1 2>&1 | jq -rR 'fromjson? | select(.exception) | .exception' | tail -40
   ```
5. Open one failing request in Jaeger: `http://127.0.0.1:16686/trace/<trace_id>` (or search service `ems-app`,
   tag `error=true`). A red SQL span = database; a red request span without SQL = application code.
6. 502/504 from nginx (not in the app metrics, but in the nginx log) mean the app did not answer at all:
   ```bash
   docker logs --since 15m ems-nginx-1 2>&1 | jq -cR 'fromjson? | select(.status >= 502)' | tail
   ```

## Mitigation

| Cause | Action |
|---|---|
| New release (burn started at a deploy) | **Roll back first, debug later:** `ansible-playbook -i ansible/inventories/aws/hosts.yml ansible/playbooks/rollback.yml -e ems_image_tag=<previous-tag>` or the `rollback.yml` workflow |
| Database unreachable | follow [EMSDatabaseDown](EMSDatabaseDown.md) |
| App container unhealthy / crash looping | `docker compose -p ems restart app`, then [ContainerRestarting](ContainerRestarting.md) |
| Resource exhaustion | [HostHighMemory](HostHighMemory.md), [HostDiskSpaceLow](HostDiskSpaceLow.md), [HostHighCPU](HostHighCPU.md) |
| Kubernetes | `kubectl -n ems rollout undo deployment/ems-app`; `kubectl -n ems get pods` |

Verify: `ems:slo_errors:ratio_rate5m` drops below 0.005 within ~5 minutes; the alert resolves once the 5-minute
window is clean (the 1h window may stay high for a while; both must be above the threshold to fire).

## Escalation

Not mitigated in 30 minutes, or the cause is outside the stack (AWS outage, account issue): escalate to the
project owner (see [oncall.md](../sre/oncall.md)), open an incident from the [template](../sre/incident-template.md).
Always write a [postmortem](../sre/postmortem-template.md): a page means budget was spent.

Related: [EMSErrorBudgetSlowBurn](EMSErrorBudgetSlowBurn.md) (inhibited while this fires), [EMSHighErrorRate](EMSHighErrorRate.md), [SLOs](../sre/slo.md), [alerting](../sre/alerting.md)
