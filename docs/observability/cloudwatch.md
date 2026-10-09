# CloudWatch: the AWS-side view (Phase 24)

Prometheus runs on the same EC2 host as the app: if the host dies, so does the monitoring. CloudWatch watches
from outside, using metrics AWS collects anyway (no agent). Everything here is created by Terraform; nothing is
clicked in the console.

| Resource | Created by | Name (dev) |
|---|---|---|
| Alarm: ALB target 5xx | `terraform/modules/load_balancer` | `ems-dev-alb-5xx` |
| Alarm: unhealthy targets | `terraform/modules/load_balancer` | `ems-dev-alb-unhealthy-hosts` |
| Alarm: host CPU | `terraform/modules/host` | `ems-dev-host-cpu-high` |
| Alarm: host status check | `terraform/modules/host` | `ems-dev-host-status-check` |
| Dashboard | `terraform/envs/dev/main.tf` (`aws_cloudwatch_dashboard`) | `ems-dev` |

Names are `${name}-...` with `name = "ems-<environment>"`, so the same alarms exist as `ems-prod-*` in `envs/prod`.

## Alarms

| Alarm | Metric (namespace) | Condition | Meaning / what to do |
|---|---|---|---|
| `ems-dev-alb-5xx` | `HTTPCode_Target_5XX_Count` (AWS/ApplicationELB), Sum | > 10 in 5 min (1 period); missing data = OK | the app returned 5xx through the ALB. Same story as the burn-rate alerts: [EMSErrorBudgetFastBurn](../runbooks/EMSErrorBudgetFastBurn.md) |
| `ems-dev-alb-unhealthy-hosts` | `UnHealthyHostCount` (AWS/ApplicationELB, per target group), Maximum | > 0 for 2 x 1 min | the target fails `GET /health` (200 expected, every 15 s, unhealthy after 3 failures). With one host this is a full outage: [EMSDatabaseDown](../runbooks/EMSDatabaseDown.md), [EMSAppDown](../runbooks/EMSAppDown.md), [EMSNoTraffic](../runbooks/EMSNoTraffic.md) |
| `ems-dev-host-cpu-high` | `CPUUtilization` (AWS/EC2), Average | > 85% for 3 x 5 min | standard-credit t3 draining credits: [HostHighCPU](../runbooks/HostHighCPU.md) |
| `ems-dev-host-status-check` | `StatusCheckFailed` (AWS/EC2), Maximum | > 0 for 2 x 1 min | hardware/hypervisor (system) or OS (instance) problem; Prometheus is probably dead too. Reboot: `aws ec2 reboot-instances --instance-ids <id>`; if the system check keeps failing, stop/start moves the instance to new hardware |

The alarms have no SNS action yet (the playground account has no paging integration). Their state is visible in
the console and via:

```bash
aws cloudwatch describe-alarms --alarm-name-prefix ems-dev- \
  --query 'MetricAlarms[].[AlarmName,StateValue,StateReason]' --output table
aws cloudwatch describe-alarm-history --alarm-name ems-dev-alb-unhealthy-hosts --max-items 5
```

To be notified, add an `aws_sns_topic` with an e-mail subscription and set `alarm_actions` / `ok_actions` on the
alarms in the modules.

## Dashboard `ems-dev`

| Widget | Metrics | Why |
|---|---|---|
| ALB requests and target 5xx | `RequestCount`, `HTTPCode_Target_5XX_Count` (Sum, 1 min) | traffic and errors as the ALB sees them, including what the app SLI misses |
| Target response time (p95) | `TargetResponseTime` p95 | latency measured at the load balancer |
| Healthy / unhealthy targets | `HealthyHostCount`, `UnHealthyHostCount` | did the health check fail, and when |
| Host CPU and credit balance | `CPUUtilization`, `CPUCreditBalance` (5 min) | CPU credits at 0 explain sudden slowness on t3 |

Open: console -> CloudWatch -> Dashboards -> `ems-dev`, or
`aws cloudwatch get-dashboard --dashboard-name ems-dev | jq -r .DashboardBody | jq`.

## Prometheus vs CloudWatch

| | Prometheus (on the host) | CloudWatch (AWS) |
|---|---|---|
| Sees | per endpoint, per container, SLO burn rates, DB state | ALB and EC2 from outside |
| Survives host failure | no | yes |
| Sees ALB 503 / nginx 502 | no (only via EMSNoTraffic / EMSAppDown) | yes (`HTTPCode_ELB_5XX_Count`, unhealthy hosts) |
| Cost | free (runs on the host) | basic metrics and a few alarms/dashboards, within or near the free tier |

## How to open the UIs (SSH tunnels)

All monitoring UIs listen on `127.0.0.1` of the host only; nothing is exposed through the ALB or the security group.

```bash
HOST=$(terraform -chdir=terraform/envs/dev output -raw host_public_ip)
ssh -N -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 -L 9093:127.0.0.1:9093 -L 16686:127.0.0.1:16686 ec2-user@"$HOST"
```

| UI | URL on your laptop |
|---|---|
| Grafana | http://localhost:3000 |
| Prometheus | http://localhost:9090 (alerts: `/alerts`, targets: `/targets`) |
| Alertmanager | http://localhost:9093 (silences, inhibited alerts) |
| Jaeger | http://localhost:16686 |

SSH is allowed only from the admin CIDR in the host security group. Kubernetes:
`kubectl -n monitoring port-forward svc/grafana 3000:3000` and `svc/prometheus 9090:9090`.
