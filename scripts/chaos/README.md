# Chaos scripts (Phase 25)

One script per game-day scenario in [docs/sre/game-days.md](../../docs/sre/game-days.md). Run them on the
**dev** environment only (on the EC2 host for the Compose scenarios, from your laptop for Kubernetes and Terraform).

| Script | Injects | Targets | Default duration | Expected signal |
|---|---|---|---|---|
| `high-cpu.sh` | a `yes` loop per core in container/pod `ems-chaos-cpu` | compose, k8s | 900 s | HostHighCPU |
| `db-timeout.sh` | `docker pause ems-db-1` / `docker compose -p ems stop db` / `scale statefulset/postgres --replicas=0` | compose, k8s | 600 s | EMSAppDown (pause), EMSDatabaseDown + EMSErrorBudgetFastBurn (stop) |
| `dns-failure.sh` | disconnect `ems-db-1` from `ems_backend` / pods with an unroutable nameserver | compose, k8s | 600 s | EMSDatabaseDown (compose), stalled rollout (k8s) |
| `image-pull-failure.sh` | deploy tag `chaos-does-not-exist` | compose, k8s | 300 s | failed deploy, no alert |
| `lb-health-check-failure.sh` | `docker compose -p ems stop nginx` (or `app`) | compose | 1200 s | `ems-dev-alb-unhealthy-hosts`, EMSNoTraffic |
| `terraform-drift.sh` | `aws ec2 create-tags` on `ems-dev-alb-sg`, then `terraform plan -detailed-exitcode` | AWS | reverts on exit | plan exit code 2 |

## Interface (the same for every script)

```bash
scripts/chaos/<scenario>.sh                 # usage, exit 2: nothing happens without an explicit action
scripts/chaos/<scenario>.sh --help
scripts/chaos/<scenario>.sh --dry-run       # print the inject AND revert commands, run nothing (works without docker/aws/kubectl)
scripts/chaos/<scenario>.sh --inject --dry-run
scripts/chaos/<scenario>.sh --inject [--target compose|k8s] [--duration SECONDS]
scripts/chaos/<scenario>.sh --revert [--target compose|k8s]
```

- `--inject` with `--duration N > 0` (the default) installs a trap: after N seconds, on Ctrl-C or on any error
  the script reverts the injection itself. `--duration 0` leaves it in place until `--revert`.
- Every command is printed with a `+` prefix before it runs; lines starting with `#` are what to observe.
- `high-cpu.sh` also limits the burner with `timeout`, so it stops even if the script is killed with SIGKILL.
- Compose scripts assume project `ems` (`--project` to change it); `image-pull-failure.sh` needs the project
  directory with `docker-compose.yml` and `.env` (`--project-dir`, default `$EMS_DIR` or `/opt/ems`).
- `terraform-drift.sh` uses the AWS credentials of your shell and `terraform/envs/dev` of this repository.

## Checks

```bash
shellcheck scripts/chaos/*.sh
./venv/bin/pytest -q tests/test_sre.py      # every script: --dry-run exits 0, has set -euo pipefail, is in game-days.md
```
