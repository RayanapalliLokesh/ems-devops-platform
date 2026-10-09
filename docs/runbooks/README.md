# Runbooks (Phase 25)

One runbook per alert in [`monitoring/prometheus/rules/ems-alerts.yml`](../../monitoring/prometheus/rules/ems-alerts.yml).
Every alert carries `runbook_url: .../docs/runbooks/<AlertName>.md`; `tests/test_sre.py` fails when an alert
has no runbook, a runbook has no alert, or this index misses one.

| Alert | Severity | Runbook |
|---|---|---|
| EMSErrorBudgetFastBurn | page | [EMSErrorBudgetFastBurn.md](EMSErrorBudgetFastBurn.md) |
| EMSErrorBudgetSlowBurn | ticket | [EMSErrorBudgetSlowBurn.md](EMSErrorBudgetSlowBurn.md) |
| EMSLatencyBudgetFastBurn | page | [EMSLatencyBudgetFastBurn.md](EMSLatencyBudgetFastBurn.md) |
| EMSLatencyBudgetSlowBurn | ticket | [EMSLatencyBudgetSlowBurn.md](EMSLatencyBudgetSlowBurn.md) |
| EMSAppDown | page | [EMSAppDown.md](EMSAppDown.md) |
| EMSDatabaseDown | page | [EMSDatabaseDown.md](EMSDatabaseDown.md) |
| EMSHighErrorRate | ticket | [EMSHighErrorRate.md](EMSHighErrorRate.md) |
| EMSHighLatency | ticket | [EMSHighLatency.md](EMSHighLatency.md) |
| EMSNoTraffic | ticket | [EMSNoTraffic.md](EMSNoTraffic.md) |
| HostHighCPU | ticket | [HostHighCPU.md](HostHighCPU.md) |
| HostHighMemory | ticket | [HostHighMemory.md](HostHighMemory.md) |
| HostDiskSpaceLow | page | [HostDiskSpaceLow.md](HostDiskSpaceLow.md) |
| ContainerHighMemory | ticket | [ContainerHighMemory.md](ContainerHighMemory.md) |
| ContainerRestarting | page | [ContainerRestarting.md](ContainerRestarting.md) |
| MonitoringTargetDown | ticket | [MonitoringTargetDown.md](MonitoringTargetDown.md) |

`page` = someone acts now, `ticket` = next working day. See [docs/sre/oncall.md](../sre/oncall.md).

## Before you start (every runbook assumes this)

```bash
# from the repository, with AWS credentials for the account
cd terraform/envs/dev
ALB=$(terraform output -raw alb_dns_name)
HOST=$(terraform output -raw host_public_ip)
cd -

# shell on the host + tunnels to Grafana, Prometheus, Alertmanager and Jaeger (they listen on 127.0.0.1 only)
ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 -L 9093:127.0.0.1:9093 -L 16686:127.0.0.1:16686 ec2-user@"$HOST"
```

On the host the stack lives in `/opt/ems` (Compose project `ems`):

```bash
cd /opt/ems
docker compose -p ems ps                                   # state + health of every container
docker logs --since 15m ems-app-1 2>&1 | jq -cR 'fromjson? | select(.status >= 500)'
sudo scripts/linux/triage.sh                               # read-only one-screen overview (if checked out on the host)
```

Ask Prometheus from your laptop (through the tunnel):

```bash
promql() { curl -s http://127.0.0.1:9090/api/v1/query --data-urlencode "query=$1" | jq -r '.data.result[] | "\(.metric) \(.value[1])"'; }
promql 'ems:slo_errors:ratio_rate5m'
```

Follow one request: the `X-Request-ID` response header (or the `request_id` in a log line) appears in the nginx
log, the app log and, through the log's `trace_id`, in Jaeger (`http://127.0.0.1:16686/trace/<trace_id>`).
See [docs/observability/logs.md](../observability/logs.md).

## Rollback, the most common mitigation

```bash
curl -s http://$ALB/health | jq -r .version                # what is running now
ansible-playbook -i ansible/inventories/aws/hosts.yml ansible/playbooks/rollback.yml -e ems_image_tag=<previous-tag>
```

or GitHub Actions -> `rollback.yml` -> Run workflow with the previous tag (the last green GitHub Release).
Kubernetes: `kubectl -n ems rollout undo deployment/ems-app`.

## Writing a new runbook

1. Add the alert with `severity` and `runbook_url` to `ems-alerts.yml` and a case to `ems-alerts-test.yml`.
2. Copy an existing runbook; keep the headings `## Meaning`, `## Impact`, `## Diagnosis`, `## Mitigation`,
   `## Escalation` and the `Related:` line. Every command must be copy-pasteable.
3. Add the row to the table above. `./venv/bin/pytest tests/test_sre.py` checks all of it.
