# ContainerRestarting

| Severity | Fires when |
|---|---|
| **page** | `changes(container_start_time_seconds{name=~"ems-.+"}[15m]) > 2` (fires immediately) |

## Meaning

An `ems-*` container started more than twice in 15 minutes: a crash loop. `restart: unless-stopped` keeps
bringing it back, so `docker compose ps` may look fine at a glance; the alert does not let it hide.

## Impact

Every restart of `app` drops in-flight requests and fails health checks for ~20 s (start period); of `db` it
is an outage each time. Usually visible as burn-rate alerts shortly after.

## Diagnosis

```bash
ssh ec2-user@$HOST
docker compose -p ems ps -a
docker inspect ems-app-1 --format 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}} started={{.State.StartedAt}}'
docker logs --tail 80 ems-app-1                 # the last lines before each exit
docker events --since 30m --filter container=ems-app-1 --filter event=die --format '{{.Time}} exit={{.Actor.Attributes.exitCode}}'
```

| Exit code / sign | Usual cause |
|---|---|
| `oom=true`, exit 137 | memory limit hit: [ContainerHighMemory](ContainerHighMemory.md) |
| exit 1 right after boot, traceback in log | bad configuration (`SECRET_KEY`, `DATABASE_URL`), missing env var, migration error, bad image |
| exit 3 / "Worker failed to boot" | gunicorn could not import the app (`run:app`) |
| unhealthy then restarted | `/health` failing: DB ([EMSDatabaseDown](EMSDatabaseDown.md)) |
| `Read-only file system` | the app writes outside `/tmp` / `/app/data` (container is `read_only: true`) |

Did it start with a deploy? `docker inspect ems-app-1 --format '{{.Config.Image}}'` vs the previous release.

## Mitigation

- After a deploy: **roll back** `ansible-playbook -i ansible/inventories/aws/hosts.yml ansible/playbooks/rollback.yml -e ems_image_tag=<previous-tag>`.
- Configuration: fix `/opt/ems/.env` (through Ansible, not by hand if possible), `docker compose -p ems up -d app`.
- OOM: raise the limit or reduce workers (see ContainerHighMemory).
- Kubernetes: `kubectl -n ems get pods` (CrashLoopBackOff), `kubectl -n ems logs <pod> --previous`,
  `kubectl -n ems rollout undo deployment/ems-app`.

## Escalation

Not stable in 15 minutes after a rollback: escalate to the owner.

Related: [EMSAppDown](EMSAppDown.md), [ContainerHighMemory](ContainerHighMemory.md), [game day image-pull-failure](../sre/game-days.md)
