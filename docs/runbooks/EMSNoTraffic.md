# EMSNoTraffic

| Severity | Fires when |
|---|---|
| **ticket** | `ems:requests:rate5m == 0` for 15 minutes |

## Meaning

The app counted no request at all (apart from `/metrics`) for 15 minutes. Even with no users the ALB health
check calls `/health` every 15 s, so zero means **nothing reaches the app**: nginx is down, the ALB no longer
forwards (listener, target deregistered), the security group blocks the ALB, or DNS points elsewhere.
Prometheus itself still reaches the app directly, so EMSAppDown stays silent. Inhibited while EMSAppDown fires.

## Impact

Probably a full outage that the app-side SLO cannot see: no requests = no errors measured. Check the ALB.

## Diagnosis

1. From outside:
   ```bash
   curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://$ALB/health    # 503 from the ALB = no healthy target; timeout = SG / ALB
   dig +short "$ALB"
   ```
2. Target health and alarms:
   ```bash
   TG=$(aws elbv2 describe-target-groups --names ems-dev-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
   aws elbv2 describe-target-health --target-group-arn "$TG" --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output table
   aws cloudwatch describe-alarms --alarm-names ems-dev-alb-unhealthy-hosts ems-dev-host-status-check --query 'MetricAlarms[].[AlarmName,StateValue]' --output table
   ```
3. On the host:
   ```bash
   docker compose -p ems ps nginx
   curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/health     # through nginx, locally
   docker logs --since 20m ems-nginx-1 2>&1 | tail
   ```
4. Drift? Someone may have changed the security groups or listener in the console:
   `scripts/chaos/terraform-drift.sh --detect` (runs `terraform plan -detailed-exitcode`; exit 2 = drift).

## Mitigation

| Finding | Action |
|---|---|
| nginx stopped | `docker compose -p ems up -d nginx` |
| Target unhealthy because `/health` fails | fix the cause ([EMSDatabaseDown](EMSDatabaseDown.md)); the target turns healthy after 2 good checks |
| Target deregistered / SG or listener changed | `terraform -chdir=terraform/envs/dev plan`, then `apply` to restore the declared state |
| Quiet period in a test environment only | silence in Alertmanager (`http://127.0.0.1:9093`, New Silence, `alertname=EMSNoTraffic`) with a reason and an end time |

## Escalation

Ticket; treat as a page if `curl http://$ALB/health` fails from outside.

Related: [EMSAppDown](EMSAppDown.md), [game day lb-health-check-failure](../sre/game-days.md), [CloudWatch](../observability/cloudwatch.md)
