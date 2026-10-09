# ContainerHighMemory

| Severity | Fires when |
|---|---|
| **ticket** | `container_memory_working_set_bytes / container_spec_memory_limit_bytes > 0.9` for an `ems-*` container, for 5 minutes |

## Meaning

A container of the stack (cAdvisor label `name`, e.g. `ems-app-1`, `ems-db-1`) uses more than 90% of its
`mem_limit` from `docker-compose.yml` / `docker-compose.monitoring.yml`. At 100% the kernel OOM-kills it inside
its cgroup, and the restart policy brings it back (then [ContainerRestarting](ContainerRestarting.md)).

## Impact

None yet. An OOM-kill of `app` drops in-flight requests (5xx/502); of `db` it causes an outage and crash recovery.

## Diagnosis

```bash
promql 'container_memory_working_set_bytes{name=~"ems-.+"} / on (name) (container_spec_memory_limit_bytes{name=~"ems-.+"} > 0)'
promql 'deriv(container_memory_working_set_bytes{name="ems-app-1"}[1h])'      # steady growth = leak
ssh ec2-user@$HOST 'docker stats --no-stream; docker inspect ems-app-1 --format "oom={{.State.OOMKilled}} restarts={{.RestartCount}}"'
```

- `ems-app-1`: each gunicorn worker holds its own copy of the app (~80-120 MB); `GUNICORN_WORKERS` x threads
  x request size decides the total. A big export or a query without pagination loads everything into memory:
  find large/slow requests with
  `docker logs --since 30m ems-app-1 2>&1 | jq -cR 'fromjson? | select(.duration_ms > 1000) | {path, duration_ms}'`.
- `ems-db-1`: `shared_buffers` + connections x `work_mem`; check `pg_stat_activity` connection count.
- `ems-prometheus-1` / `ems-jaeger-1`: series or trace count growth (cardinality, `MEMORY_MAX_TRACES`).

## Mitigation

- Short term: `docker compose -p ems restart <service>` (app: no downtime beyond a few seconds of 502).
- App: lower `GUNICORN_WORKERS` or raise `mem_limit` (Compose file via a reviewed change, deployed by Ansible).
- A leak introduced by a release: roll back (`ansible/playbooks/rollback.yml -e ems_image_tag=<previous-tag>`).
- Kubernetes: `kubectl -n ems top pods`; raise `resources.limits.memory` in `k8s/base/app-deployment.yaml`.

## Escalation

Ticket for the owner of the service; page only once restarts begin.

Related: [ContainerRestarting](ContainerRestarting.md), [HostHighMemory](HostHighMemory.md)
