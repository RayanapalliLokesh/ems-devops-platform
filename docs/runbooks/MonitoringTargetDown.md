# MonitoringTargetDown

| Severity | Fires when |
|---|---|
| **ticket** | `up{job!="ems-app"} == 0` for 5 minutes (jobs `node`, `cadvisor`, `prometheus`, `alertmanager`) |

## Meaning

Prometheus cannot scrape part of the monitoring platform. The app may be fine; what is broken is our ability
to see it. Which alerts go blind depends on the job:

| Job down | Blind alerts |
|---|---|
| `node` (node-exporter) | HostHighCPU, HostHighMemory, HostDiskSpaceLow |
| `cadvisor` | ContainerHighMemory, ContainerRestarting |
| `alertmanager` | **all notifications** (alerts fire in Prometheus but reach nobody) |
| `prometheus` | self-scrape; if Prometheus is really down, nothing fires at all (CloudWatch alarms still do) |

## Impact

No user impact; reduced detection. An Alertmanager outage is the most serious: treat it as urgent.

## Diagnosis

```bash
# browse http://127.0.0.1:9090/targets via the SSH tunnel: last scrape error per target
ssh ec2-user@$HOST 'cd /opt/ems && docker compose -p ems -f docker-compose.yml -f docker-compose.monitoring.yml ps'
docker logs --tail 50 ems-node-exporter-1       # or ems-cadvisor-1, ems-alertmanager-1
docker inspect ems-cadvisor-1 --format 'oom={{.State.OOMKilled}} restarts={{.RestartCount}}'
```
Common causes: OOM-kill (cadvisor at 192m on a host with many containers), the container on the wrong network
after a manual `docker run`, a config error after editing `alertmanager.yml`
(`docker run --rm -v $PWD/monitoring/alertmanager:/c:ro --entrypoint amtool prom/alertmanager:v0.27.0 check-config /c/alertmanager.yml`).

## Mitigation

```bash
cd /opt/ems
docker compose -p ems -f docker-compose.yml -f docker-compose.monitoring.yml up -d <service>
curl -s -X POST http://127.0.0.1:9090/-/reload      # after a prometheus.yml / rules change (lifecycle API is on)
```
Raise `mem_limit` if it was OOM-killed. Check rules before reloading:
`docker run --rm -v $PWD/monitoring/prometheus:/p:ro --entrypoint promtool prom/prometheus:v2.55.1 check rules /p/rules/ems-alerts.yml /p/rules/ems-slo.yml`.

## Escalation

Ticket. If Alertmanager is down for more than an hour, tell the on-call that only CloudWatch alarms are active.

Related: [alerting flow](../observability/alerting-flow.md), [HostDiskSpaceLow](HostDiskSpaceLow.md) (a full disk stops Prometheus), [ContainerRestarting](ContainerRestarting.md)
