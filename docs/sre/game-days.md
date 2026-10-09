# Game days (Phase 25)

A game day injects a known failure on purpose, with a hypothesis written down first, to check that the
alerts fire, the runbooks work and the people know what to do. Scripts: [`scripts/chaos/`](../../scripts/chaos/README.md).
Every script prints what it would do with `--dry-run`, injects only with `--inject`, and undoes the injection
with `--revert` (or automatically after `--duration`).

## Rules

- Only on the **dev** environment (EC2 Compose project `ems`, or the kind/k8s variant), never on anything users depend on.
- Only when less than 50% of the weekly error budget is spent ([error-budget-policy.md](error-budget-policy.md)).
  The game day spends budget; that is accepted.
- Announce start and end in the channel; one person injects, one person is "on call" and follows the
  runbook *without* knowing which scenario was picked (when there are two people).
- Run `--dry-run` first and read the commands. Have the `--revert` command ready in a second terminal.
- Abort if anything unexpected happens outside the scenario: revert, then write down why.
- Afterwards: fill in the result table below, and write a postmortem for any scenario where the outcome
  differed from the hypothesis ([example](postmortems/2026-10-example-db-timeout.md)).

## Schedule

Monthly, first Thursday, 10:00-12:00 UTC, one or two scenarios per session.

| Month | Scenario(s) | Target |
|---|---|---|
| 2026-10 | db-timeout (pause), lb-health-check-failure | compose (EC2) |
| 2026-11 | high-cpu, image-pull-failure | compose (EC2) |
| 2026-12 | dns-failure, terraform-drift | compose (EC2), Terraform dev |
| 2027-01 | db-timeout, dns-failure, image-pull-failure | k8s (kind) |
| 2027-02 | db-timeout (stop) as an unannounced drill for the on-call person | compose (EC2) |
| 2027-03 | repeat any scenario whose last result was "differs" | |

## Steady state (check before every scenario)

```bash
curl -s http://$ALB/health | jq                         # status healthy, database healthy
for i in $(seq 20); do curl -s -o /dev/null -w '%{http_code}\n' http://$ALB/api/employees; done | sort | uniq -c   # 20 x 200
```
```promql
up{job="ems-app"} == 1
ems_db_up == 1
ems:slo_errors:ratio_rate5m < 0.005
ems:slo_latency:ratio_rate5m < 0.05
ALERTS{alertstate="firing"}                              # empty
```
Keep a little load running during the scenario so the SLIs move:
`while true; do curl -s -o /dev/null http://$ALB/api/employees; sleep 0.5; done`

---

## high-cpu

**Script:** `scripts/chaos/high-cpu.sh` (`--inject --duration 900`, `--target compose|k8s`)

| | |
|---|---|
| Hypothesis | Burning every core for 15 minutes fires **HostHighCPU** (ticket) after ~12-15 minutes. The latency SLO holds (p95 < 500 ms) while CPU credits last; no page. |
| Pre-check | CloudWatch `CPUCreditBalance` (dashboard `ems-dev`) above 100, or the burn drains the host to baseline. |
| Inject | `scripts/chaos/high-cpu.sh --inject --duration 900` (a `yes` loop per core in container `ems-chaos-cpu`) |
| Observe | Grafana USE "Host CPU utilisation", "Host load (saturation)"; RED "Duration p95"; `docker stats` |
| Expected alert | `HostHighCPU` (Prometheus), later `ems-dev-host-cpu-high` (CloudWatch, 3 x 5 min) |
| Rollback | automatic after 900 s; manual `scripts/chaos/high-cpu.sh --revert` |

## db-timeout

**Script:** `scripts/chaos/db-timeout.sh` (`--mode pause|stop`, `--target compose|k8s`)

| | |
|---|---|
| Hypothesis | `stop`: **EMSDatabaseDown** pages within 2 minutes, `/health` answers 503, the ALB target goes unhealthy, **EMSErrorBudgetFastBurn** follows within ~10 minutes. `pause`: queries hang instead of failing; `/metrics` times out, so **EMSAppDown** fires (and inhibits EMSDatabaseDown). Recovery is automatic after revert, without restarting the app. |
| Inject | `scripts/chaos/db-timeout.sh --inject --mode stop --duration 600` (or `--mode pause`) |
| Observe | `curl -w '%{http_code} %{time_total}'` on `/health`; `ems_db_up`, `up{job="ems-app"}`; app log errors; Jaeger: SQL spans in error / very long |
| Expected alert | stop: `EMSDatabaseDown` then `EMSErrorBudgetFastBurn`; pause: `EMSAppDown`; CloudWatch `ems-dev-alb-unhealthy-hosts` in both |
| Rollback | automatic; manual `scripts/chaos/db-timeout.sh --revert --mode <mode>` |

## dns-failure

**Script:** `scripts/chaos/dns-failure.sh` (`--target compose|k8s`)

| | |
|---|---|
| Hypothesis | compose: with `db` removed from the backend network the name stops resolving; **EMSDatabaseDown** fires within 2 minutes and the app log says `could not translate host name "db"`. k8s: new pods with a broken resolver never become ready; the rollout stalls, the old pods keep serving, **no alert and no user impact**. |
| Inject | `scripts/chaos/dns-failure.sh --inject --duration 600` / `--target k8s` |
| Observe | `docker exec ems-app-1 python -c "import socket; socket.gethostbyname('db')"`; app log; k8s: `kubectl -n ems get pods`, `kubectl -n ems rollout status deployment/ems-app` |
| Expected alert | compose: `EMSDatabaseDown`, then `EMSErrorBudgetFastBurn`; k8s: none |
| Rollback | compose: reconnect with alias `db`; k8s: `kubectl -n ems rollout undo deployment/ems-app` (both done by `--revert`) |

## image-pull-failure

**Script:** `scripts/chaos/image-pull-failure.sh` (`--tag`, `--target compose|k8s`)

| | |
|---|---|
| Hypothesis | Deploying a tag that does not exist fails **before** the running version is touched: compose keeps the old container, Kubernetes keeps the old ReplicaSet (`maxUnavailable: 0`). `/health` stays 200, the SLIs do not move, no alert. The failure is visible in the deploy output (and in CD, which must go red). |
| Inject | `scripts/chaos/image-pull-failure.sh --inject` (compose, on the host in `/opt/ems`) / `--target k8s --image <repo>` |
| Observe | the `up` / `set image` output (`manifest unknown`); `docker compose -p ems ps app` (image tag unchanged); k8s: `ErrImagePull`/`ImagePullBackOff` in `kubectl -n ems get pods` |
| Expected alert | none (and no `ContainerRestarting`) |
| Rollback | `scripts/chaos/image-pull-failure.sh --revert` (redeploys the tag from `.env` / `rollout undo`) |

## lb-health-check-failure

**Script:** `scripts/chaos/lb-health-check-failure.sh` (`--mode stop-nginx|stop-app`)

| | |
|---|---|
| Hypothesis | With nginx stopped, the ALB marks the target unhealthy after 3 failed checks (45 s) and returns 503 itself. CloudWatch **`ems-dev-alb-unhealthy-hosts`** fires within ~3 minutes. Prometheus still scrapes the app directly, so the only Prometheus alert is **EMSNoTraffic** after ~20 minutes: a known detection gap on the Prometheus side. |
| Inject | `scripts/chaos/lb-health-check-failure.sh --inject --duration 1200` |
| Observe | `aws elbv2 describe-target-health ...`; `curl -i http://$ALB/` (503 from `awselb`); `ems:requests:rate5m` dropping to 0 |
| Expected alert | CloudWatch `ems-dev-alb-unhealthy-hosts`; Prometheus `EMSNoTraffic` (ticket) |
| Rollback | automatic; manual `scripts/chaos/lb-health-check-failure.sh --revert` |

## terraform-drift

**Script:** `scripts/chaos/terraform-drift.sh` (needs AWS credentials and `terraform init` in `terraform/envs/dev`)

| | |
|---|---|
| Hypothesis | A tag added to the ALB security group by hand (`aws ec2 create-tags`) is reported by `terraform plan -detailed-exitcode` (exit code **2**, an in-place update of `module.security_groups.aws_security_group.alb` tags). After the tag is removed again the plan exits **0**. No runtime alert exists for drift. |
| Inject | `scripts/chaos/terraform-drift.sh --inject` (tags, plans, and reverts on exit; `--keep` to leave it) |
| Observe | the plan output (`~ tags`, `~ tags_all`) and its exit code |
| Expected alert | none; detection is the plan. Follow-up idea: a scheduled `plan -detailed-exitcode` workflow that opens an issue on exit 2. |
| Rollback | automatic (`aws ec2 delete-tags`, then plan again); manual `scripts/chaos/terraform-drift.sh --revert` |

---

## Results (fill in after each run)

| Date | Scenario | Target / mode | Alert expected | Alert fired (time after inject) | Runbook followed | Recovered after revert | Outcome (as expected / differs) | Notes / postmortem |
|---|---|---|---|---|---|---|---|---|
| 2026-10-08 | db-timeout | compose / pause | EMSAppDown | EMSAppDown (+2 min) | EMSAppDown.md | yes, 40 s | differs (see postmortem) | [2026-10-example-db-timeout](postmortems/2026-10-example-db-timeout.md) - exercise |
| | high-cpu | | HostHighCPU | | | | | |
| | dns-failure | | EMSDatabaseDown | | | | | |
| | image-pull-failure | | none | | | | | |
| | lb-health-check-failure | | ems-dev-alb-unhealthy-hosts, EMSNoTraffic | | | | | |
| | terraform-drift | | plan exit 2, then 0 | | | | | |
