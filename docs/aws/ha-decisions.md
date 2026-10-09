# High availability: what happens when X fails?

The dev platform is deliberately **one host**: the playground limits instances and credits, and the goal is a
working, observable, reproducible system - not a highly available one. This page says honestly where it breaks and
what a production design changes.

| Failure | What happens in dev | Detection | Recovery (dev) | What prod changes |
|---|---|---|---|---|
| **EC2 host dies** (hardware, kernel panic, terminated) | full outage: the ALB has no healthy target and returns 503. The database lives on the same host - **single point of failure** | `ems-dev-alb-unhealthy-hosts`, `ems-dev-host-status-check`; Prometheus is down too (it runs on the host) | status check failure: reboot or stop/start (new hardware, same EBS). Terminated: `terraform apply` recreates it (~3 min), Ansible deploys (~5 min), restore the latest `pg_dump` from S3. RPO up to 24 h (nightly backup), RTO ~15-30 min | two or more hosts in an Auto Scaling group across both zones; the database moves off the host (RDS Multi-AZ) so app hosts are stateless |
| **Availability zone fails** | if it is the host's zone: same as "host dies". If it is the other zone: nothing (the ALB keeps serving from the healthy zone) | same alarms | recreate the host in the other public subnet (`subnet_id = public_subnet_ids[1]`) and restore | ASG spans both zones; RDS Multi-AZ fails over automatically; one NAT gateway **per zone** so the surviving zone keeps outbound access (that is why prod has `nat_gateways = 2`) |
| **Database container dies** | `/health` returns 503, the target goes unhealthy, the ALB returns 503; Docker restarts the container (`restart: unless-stopped`), the app reconnects | `EMSDatabaseDown`, `ems-dev-alb-unhealthy-hosts` | usually automatic within a minute; data is on a Docker volume on the EBS root disk. Corruption: restore from S3 (`ansible/roles/ems_stack/tasks/restore.yml`) | managed database with automated backups and point-in-time recovery |
| **App container dies / bad release** | nginx returns 502; Docker restarts it. A bad release fails its health check during the deploy and Ansible restores the previous tag | `EMSAppDown`, `EMSHighErrorRate`, ALB 5xx alarm | automatic, or `rollback.yml` with the previous tag | rolling deploys across several hosts, so one bad host is drained by the ALB |
| **ALB** | the ALB is a managed, multi-zone service; AWS replaces failed nodes. A regional ELB outage is a full outage | ALB metrics missing / `EMSNoTraffic` | wait (AWS); nothing to fix on our side | the same; multi-region with Route 53 failover only if the business needs it |
| **ECR unavailable** | running containers keep running (images are cached on the host). Deploys and a recreated host cannot pull | deploy fails at `docker pull` | retry later; the previous image stays cached | the same images are also in ghcr.io (CD builds there first), so a deploy can fall back; cross-region ECR replication |
| **Terraform state bucket lost** | no effect on the running system. Terraform no longer knows what it owns: a plan wants to create everything | `terraform plan` shows all resources as new | restore a previous object version (bucket is versioned). If the bucket itself is gone: recreate it with `bootstrap-state` and `import` the resources, or destroy them by tag and re-apply | bucket in a separate, locked-down account with deletion protection and replication |
| **Playground session expires** | the whole account is wiped: host, ALB, backups, ECR, state. Everything is lost except what is in git | - | start a new session: `aws-playground.sh bootstrap`, `registry`, `up`, push the image, `deploy`. ~20 minutes. Data: none (the backups were in the same account) | not applicable; in a real account backups are copied to a second account/region |
| **Admin IP changes** | SSH is refused (the rule allows the old `/32`); the app keeps serving | SSH timeout | `aws-playground.sh up` rewrites `terraform.tfvars` with the new IP and applies the one-rule change | no SSH at all: SSM Session Manager |
| **CPU credits exhausted** | the t3 is throttled to its baseline: slow responses, no outage | `ems-dev-host-cpu-high`, `CPUCreditBalance` at 0, `EMSHighLatency` | find the CPU consumer (`HostHighCPU` runbook); wait for credits | larger or non-burstable instances, more hosts |

## Single points of failure in dev (accepted)

1. One EC2 host runs nginx, the app **and** PostgreSQL.
2. Backups are in the same account (and the same region) as the data.
3. Monitoring (Prometheus, Alertmanager, Grafana) runs on the host it monitors; CloudWatch alarms are the outside
   view, but they have no notification target yet.

## Already in place

ALB in two zones with a database-aware health check, automatic container restarts, automatic rollback of failed
deploys, nightly encrypted backups with expiry, CloudWatch alarms independent of the host, infrastructure that can
be rebuilt from git in ~20 minutes.
