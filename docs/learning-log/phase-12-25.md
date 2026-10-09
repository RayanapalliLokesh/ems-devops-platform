# Phases 12-25 - From one Flask app to a platform

## What I built
The Phase 11 application, unchanged in purpose, now runs as an immutable image behind nginx, with PostgreSQL, on an
EC2 host behind an ALB in a Terraform-built VPC, configured by Ansible, shipped by GitHub Actions (CI on every push,
CD on a version tag with approval and automatic rollback), observable through metrics, JSON logs, traces and
SLO burn-rate alerts with a runbook each. The same image runs on kind with Kustomize.

## What went wrong and how I found it
| Symptom | Command that showed it | Cause | Fix |
|---|---|---|---|
| app container: `exec /opt/venv/bin/gunicorn: operation not permitted` | `docker run --security-opt no-new-privileges ...` one option at a time | `no-new-privileges` with the host's AppArmor profile | option dropped, documented in docs/docker/image-review.md |
| workers fail to boot: `No module named 'psycopg'` | `docker compose logs app` | SQLAlchemy was unpinned; 2.1 switched the default PostgreSQL driver to psycopg 3 | pin SQLAlchemy 2.1.4 + psycopg 3 |
| 502 from nginx after the app container was recreated | `curl -i`, `docker compose ps` | nginx resolved `app` once at start and kept the old IP | `resolver 127.0.0.11` + `server app:5000 resolve` (nginx 1.27.4) |
| `/metrics` answered 200 from outside | `curl localhost:8080/metrics` | the allow-list of private ranges also matches the ALB (10.x) | `/metrics` returns 404 at nginx and 403 at the Ingress; Prometheus scrapes the app directly |
| `terraform apply`: AccessDenied `iam:PutRolePolicy`, then `iam:TagPolicy` | the apply error | playground denies inline role policies and policy tags | managed policy + attachment, created through an untagged provider alias |
| `Invalid for_each argument` | `terraform plan` | instance IDs unknown at plan time | map with static keys (`{ host = id }`) |
| `curl-minimal conflicts with curl` | Ansible `dnf` task | Amazon Linux 2023 ships curl-minimal | package removed from the list |
| backup upload AccessDenied | `journalctl -u ems-backup.service` | script used prefix `db/`, IAM policy allows `backups/` | prefix aligned with the policy and lifecycle rule |

## What I would do differently
Pin every transitive dependency that changes behaviour (SQLAlchemy) from the first day, and read the playground's
IAM rules before writing the first IAM resource.

## Evidence
`ansible-playbook ... site.yml` second run `changed=0`; `curl http://<alb>/health` serves the deployed tag;
`promtool test rules` SUCCESS; `k8s-rollout.sh --tag does-not-exist` rolled back by itself.
