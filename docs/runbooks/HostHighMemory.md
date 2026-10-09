# HostHighMemory

| Severity | Fires when |
|---|---|
| **ticket** | `100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 90` for 10 minutes |

## Meaning

Less than 10% of the host's memory is available (page cache that can be dropped already counts as available).
Next steps are swapping (if configured) and the kernel OOM killer, which may pick PostgreSQL.

## Impact

None yet; then latency spikes and containers being killed ([ContainerRestarting](ContainerRestarting.md),
[EMSDatabaseDown](EMSDatabaseDown.md)).

## Diagnosis

```bash
ssh ec2-user@$HOST
free -m
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}'
ps aux --sort=-rss | head -10
sudo dmesg -T | grep -i -E 'out of memory|killed process' | tail
```
```bash
promql 'topk(5, container_memory_working_set_bytes{name=~"ems-.+"})'
promql 'node_memory_MemAvailable_bytes / 1024 / 1024'
```

Sum of the Compose `mem_limit` values (app 512m, db 512m, nginx 128m, prometheus 512m, jaeger 384m, grafana 256m,
cadvisor 192m, alertmanager 128m, node-exporter 64m = ~2.7 GB) versus the instance's RAM: on a 2 GB t3.small the
limits are overcommitted by design, so a single container growing to its limit can starve the host.

## Mitigation

- A container growing without bound: restart it (`docker compose -p ems restart <service>`), open a ticket for
  the leak (gunicorn already recycles workers every ~1000 requests).
- Too many gunicorn workers: lower `GUNICORN_WORKERS` in `/opt/ems/.env`, `docker compose -p ems up -d app`.
- Monitoring stack too heavy for the instance: lower `MEMORY_MAX_TRACES` (Jaeger) or stop Jaeger
  (`docker compose -p ems stop jaeger`; tracing is optional).
- Long-term: bigger `instance_type` in `terraform/envs/dev`.

## Escalation

Ticket. Page only if containers start being OOM-killed.

Related: [ContainerHighMemory](ContainerHighMemory.md), [ContainerRestarting](ContainerRestarting.md), [dashboards (USE)](../observability/dashboards.md)
