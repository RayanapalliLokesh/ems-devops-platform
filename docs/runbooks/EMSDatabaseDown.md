# EMSDatabaseDown

| Severity | Fires when |
|---|---|
| **page** | `ems_db_up == 0` for 1 minute (the `SELECT 1` run by every `/metrics` and `/health` call fails) |

## Meaning

The app is running but cannot talk to PostgreSQL: the db container is stopped, unhealthy, out of disk, out of
connections, or the name `db` does not resolve (network/DNS). `/health` answers **503**, so the ALB marks the
only target unhealthy after 3 failed checks (45 s) and starts answering 503 itself.
Inhibited while [EMSAppDown](EMSAppDown.md) fires (a hanging DB usually shows up as EMSAppDown).

## Impact

Full outage of every data endpoint, and the ALB health checks themselves count as 5xx: expect
[EMSErrorBudgetFastBurn](EMSErrorBudgetFastBurn.md) within minutes.

## Diagnosis

1. What the app says:
   ```bash
   curl -s http://$ALB/health | jq            # via ALB (may be the ALB's own 503 page)
   ssh ec2-user@$HOST 'curl -s http://127.0.0.1/health'   # via nginx on the host: the app's own answer
   docker logs --since 10m ems-app-1 2>&1 | jq -rR 'fromjson? | select(.message | test("Health check failed")) | .message' | tail -3
   ```
   The message names the driver error: `could not translate host name "db"` (DNS / network),
   `connection refused` (db down), `too many clients` (connections), `timeout` (db hanging).
2. The database container:
   ```bash
   docker compose -p ems ps db
   docker inspect ems-db-1 --format '{{.State.Status}} health={{.State.Health.Status}} oom={{.State.OOMKilled}}'
   docker exec ems-db-1 pg_isready -U ems -d ems
   docker logs --tail 50 ems-db-1             # "No space left on device", "FATAL", crash recovery
   ```
3. Network and name resolution (the `dns-failure` game day):
   ```bash
   docker exec ems-app-1 python -c "import socket; print(socket.gethostbyname('db'))"
   docker network inspect ems_backend --format '{{range .Containers}}{{.Name}} {{end}}'   # is ems-db-1 listed?
   ```
4. Disk (PostgreSQL stops writing at 100%): `df -h /`, see [HostDiskSpaceLow](HostDiskSpaceLow.md).
5. Connections: `docker exec ems-db-1 psql -U ems -d ems -c 'select count(*), state from pg_stat_activity group by state'`

## Mitigation

| Finding | Action |
|---|---|
| db stopped / exited | `docker compose -p ems up -d db` (data lives in volume `ems_db-data`) |
| db paused | `docker unpause ems-db-1` |
| db not on the backend network | `docker network connect --alias db ems_backend ems-db-1` |
| Disk full | free disk first ([HostDiskSpaceLow](HostDiskSpaceLow.md)), then `docker compose -p ems restart db` |
| Too many connections | `docker compose -p ems restart app` (resets the pools); lower `GUNICORN_WORKERS` x threads |
| Data corruption / volume lost | restore the newest dump: `sudo scripts/linux/backup-db.sh --restore /var/backups/ems/<file>.sql.gz` (or download it from the S3 backup bucket first: `aws s3 ls s3://$(terraform -chdir=terraform/envs/dev output -raw backup_bucket)/backups/`) |
| Kubernetes | `kubectl -n ems get statefulset postgres`, `kubectl -n ems scale statefulset/postgres --replicas=1`, `kubectl -n ems logs postgres-0` |

Verify: `ems_db_up` is 1, `curl http://$ALB/health` returns `"database": "healthy"`, the ALB target is healthy.

## Escalation

A restore means data loss since the last backup: tell the owner before restoring. Not mitigated in 15 minutes:
escalate. Postmortem required.

Related: [EMSAppDown](EMSAppDown.md), [HostDiskSpaceLow](HostDiskSpaceLow.md), [game day db-timeout / dns-failure](../sre/game-days.md), [example postmortem](../sre/postmortems/2026-10-example-db-timeout.md)
