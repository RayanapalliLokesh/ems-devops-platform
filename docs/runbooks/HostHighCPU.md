# HostHighCPU

| Severity | Fires when |
|---|---|
| **ticket** | `100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))) > 85` for 10 minutes |

## Meaning

The EC2 host (all cores averaged) has been more than 85% busy for 10 minutes. The host is a t3 with
**standard** credits: above the baseline it spends CPU credits, and at zero credits AWS throttles it to the
baseline (20-30% of a core), which turns "busy" into "slow for everyone". The AWS-side twin is the CloudWatch
alarm `ems-dev-host-cpu-high` (85% for 15 minutes).

## Impact

No direct SLO impact while credits last. Once they are gone, latency rises for every request
([EMSLatencyBudgetFastBurn](EMSLatencyBudgetFastBurn.md)).

## Diagnosis

1. Who is using the CPU:
   ```bash
   ssh ec2-user@$HOST
   docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
   top -b -n 1 -o %CPU | head -15
   docker ps --filter label=ems.chaos      # a leftover game-day burner (scripts/chaos/high-cpu.sh)?
   ```
   ```bash
   promql 'sum by (name) (rate(container_cpu_usage_seconds_total{name=~"ems-.+"}[5m]))'
   promql 'node_load1 / count(node_cpu_seconds_total{mode="idle"})'      # > 1 = runnable queue longer than cores
   ```
2. Credits (CloudWatch dashboard `ems-dev`, panel "Host CPU and credit balance"):
   ```bash
   aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUCreditBalance \
     --dimensions Name=InstanceId,Value=$(terraform -chdir=terraform/envs/dev output -raw host_instance_id) \
     --start-time $(date -u -d '-3 hours' +%FT%TZ) --end-time $(date -u +%FT%TZ) --period 300 --statistics Average \
     --query 'sort_by(Datapoints,&Timestamp)[-6:].[Timestamp,Average]' --output table
   ```
3. Is the app the consumer? Request rate up (`ems:requests:rate5m`) = load; rate flat but app CPU up = a
   regression (check the last deploy) or a hot loop.

## Mitigation

| Finding | Action |
|---|---|
| Chaos container left running | `scripts/chaos/high-cpu.sh --revert` (or `docker rm -f ems-chaos-cpu`) |
| Real traffic growth | bigger `instance_type` in `terraform/envs/dev` (plan, apply in a window), or move to the k8s variant and scale `ems-app` |
| App regression | roll back: `ansible/playbooks/rollback.yml -e ems_image_tag=<previous-tag>` |
| Runaway process outside Docker | identify with `top`, stop the systemd unit or kill it; note it in the ticket |
| cAdvisor / Prometheus itself heavy | raise scrape interval or reduce retention in `docker-compose.monitoring.yml` |

## Escalation

Ticket. Page only if latency SLOs start burning. Capacity changes (instance type) go through Terraform review.

Related: [EMSLatencyBudgetFastBurn](EMSLatencyBudgetFastBurn.md), [EMSHighLatency](EMSHighLatency.md), [game day high-cpu](../sre/game-days.md), [CloudWatch](../observability/cloudwatch.md)
