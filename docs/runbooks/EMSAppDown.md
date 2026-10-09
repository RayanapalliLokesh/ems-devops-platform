# EMSAppDown

| Severity | Fires when |
|---|---|
| **page** | `up{job="ems-app"} == 0` for 1 minute |

## Meaning

Prometheus cannot scrape `http://app:5000/metrics`: the app container is down, not on the network, or too busy
to answer within the 10 s scrape timeout. Note that `/metrics` runs `SELECT 1`, so a **hanging** database
(paused, locked) also makes the scrape time out and fires this alert instead of EMSDatabaseDown.
While it fires, Alertmanager inhibits EMSHighErrorRate, EMSHighLatency, EMSNoTraffic and EMSDatabaseDown.

## Impact

Probably a full outage: if the app cannot answer Prometheus, it cannot answer users. Also, the SLO metrics are
blind while it lasts (no samples = no measured errors), so check the ALB numbers for the real impact.

## Diagnosis

1. From outside:
   ```bash
   curl -s -m 5 -o /dev/null -w '%{http_code} %{time_total}s\n' http://$ALB/health    # 502 = nginx up, app down; 503 from ALB = no healthy target
   aws elbv2 describe-target-health --target-group-arn "$(aws elbv2 describe-target-groups --names ems-dev-tg --query 'TargetGroups[0].TargetGroupArn' --output text)"
   ```
2. On the host:
   ```bash
   docker compose -p ems ps                    # app: running? healthy? restarting?
   docker logs --tail 50 ems-app-1             # gunicorn boot errors, tracebacks, "WORKER TIMEOUT"
   docker inspect ems-app-1 --format '{{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}'
   ```
3. Is it the scrape path only? From the Prometheus container:
   ```bash
   docker exec ems-prometheus-1 wget -qO- -T 5 http://app:5000/livez     # process alive?
   docker exec ems-prometheus-1 wget -qO- -T 12 http://app:5000/metrics | head -3
   ```
   `/livez` fast but `/metrics` hangs = the database hangs (`docker exec ems-db-1 pg_isready`, `docker inspect ems-db-1 --format '{{.State.Status}}'` shows `paused`?).
4. Prometheus view: `http://127.0.0.1:9090/targets` shows the last scrape error (connection refused, timeout, DNS).

## Mitigation

| Finding | Action |
|---|---|
| Container exited / unhealthy | `docker compose -p ems up -d app` (it waits for db healthy) |
| Crash loop right after a deploy | roll back: `ansible-playbook -i ansible/inventories/aws/hosts.yml ansible/playbooks/rollback.yml -e ems_image_tag=<previous-tag>` |
| OOMKilled | see [ContainerHighMemory](ContainerHighMemory.md); lower `GUNICORN_WORKERS` or raise `mem_limit` |
| DB paused / hanging | `docker unpause ems-db-1` or `docker compose -p ems restart db`; then [EMSDatabaseDown](EMSDatabaseDown.md) |
| Host unreachable (SSH fails too) | CloudWatch alarm `ems-dev-host-status-check`; `aws ec2 reboot-instances --instance-ids $(terraform -chdir=terraform/envs/dev output -raw host_instance_id)` |
| Kubernetes | `kubectl -n ems get pods`, `kubectl -n ems describe pod <pod>`, `kubectl -n ems rollout undo deployment/ems-app` |

Verify: `curl http://$ALB/health` answers 200 and `up{job="ems-app"}` is 1.

## Escalation

Not back within 15 minutes: escalate to the owner; if the EC2 host itself is gone, recreate it with
`terraform apply` in `terraform/envs/dev` and redeploy with Ansible (restore data with `scripts/linux/backup-db.sh --restore`).

Related: [ContainerRestarting](ContainerRestarting.md), [EMSDatabaseDown](EMSDatabaseDown.md), [EMSNoTraffic](EMSNoTraffic.md), [alerting flow](../observability/alerting-flow.md)
