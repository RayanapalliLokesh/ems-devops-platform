# HostDiskSpaceLow

| Severity | Fires when |
|---|---|
| **page** | less than 15% free on `/` (`node_filesystem_avail_bytes / node_filesystem_size_bytes`, non-tmpfs) for 5 minutes |

## Meaning

The root filesystem of the host is almost full. Docker images, container logs, the PostgreSQL volume, the
Prometheus TSDB and local backups (`/var/backups/ems`) all live on it.

## Impact

At 100% PostgreSQL can no longer write WAL and stops accepting writes (then [EMSDatabaseDown](EMSDatabaseDown.md)),
Docker cannot pull images (deploys fail), Prometheus stops ingesting. It is a page because the remaining time
can be short and recovery from a full disk is harder than prevention.

## Diagnosis

```bash
ssh ec2-user@$HOST
df -h /
docker system df                                  # images, containers, volumes, build cache
sudo du -xh --max-depth=2 /var/lib/docker 2>/dev/null | sort -rh | head
sudo du -sh /var/backups/ems /var/log/journal 2>/dev/null
sudo find /var/lib/docker/containers -name '*-json.log' -size +100M -exec ls -lh {} \;   # unrotated container logs
```
How fast is it filling (hours left):
```bash
promql 'predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[6h], 24*3600) < 0'
promql 'node_filesystem_avail_bytes{mountpoint="/"} / -deriv(node_filesystem_avail_bytes{mountpoint="/"}[1h]) / 3600'
```

## Mitigation

In order, safest first:

1. Old images (every deploy leaves one): `docker image prune -a --filter "until=168h"` (keeps images used by
   running containers; keep the previous tag if you may need to roll back to it).
2. Build cache: `docker builder prune -f`.
3. Huge container logs: `sudo truncate -s 0 /var/lib/docker/containers/<id>/<id>-json.log`, then configure
   rotation (`log-opts: max-size=10m, max-file=3` in `/etc/docker/daemon.json`, via Ansible).
4. Local backups: they are also in S3, so keep the last 2:
   `ls -t /var/backups/ems/*.sql.gz | tail -n +3 | xargs -r sudo rm` (first check `aws s3 ls s3://<backup-bucket>/backups/`).
5. Journal: `sudo journalctl --vacuum-size=200M`.
6. Prometheus TSDB: retention is 7 d; if it grew, `docker compose -p ems restart prometheus` after lowering it.
7. Still not enough: grow the EBS root volume (`volume_size_gb` of the host module in Terraform; it changes in place),
   then `sudo growpart /dev/nvme0n1 1 && sudo xfs_growfs /`.

Never delete files inside the PostgreSQL volume (`ems_db-data`) by hand.

## Escalation

If PostgreSQL already stopped: page the owner, follow [EMSDatabaseDown](EMSDatabaseDown.md), take a fresh backup
(`sudo scripts/linux/backup-db.sh --s3-bucket <bucket>`) as soon as it is up.

Related: [EMSDatabaseDown](EMSDatabaseDown.md), [MonitoringTargetDown](MonitoringTargetDown.md), [dashboards (USE)](../observability/dashboards.md)
