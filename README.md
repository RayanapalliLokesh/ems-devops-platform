# EMS DevOps/SRE Platform

An Employee Management System (Flask + PostgreSQL) and everything around it that a production service needs:
container image, reverse proxy, Terraform-built AWS network and compute, Ansible configuration, GitHub Actions CI/CD
with approval and rollback, Kubernetes manifests, metrics/logs/traces, and SLO-based alerting with runbooks.

There is one application and it never changes its job. Phases 12-25 change how it is run, reached, shipped,
described and watched (see `docs/capstone/architecture.md` and `CHANGELOG.md`).

```
developer ── git push ──► CI: lint · tests · scan · image                      (.github/workflows/ci.yml)
          ── git tag ───► CD: build once → ECR → approval → Ansible → smoke test (.github/workflows/cd.yml)
                                                     │                 rollback.yml: redeploy an older tag
Terraform (terraform/envs/dev) ──────────────────────▼──────────────────────────────────────────────────
  VPC 10.0.0.0/16 · 2 public + 2 private subnets · IGW · SG alb (80 from all) · SG host (80 from ALB, 22 admin)
  users ─https─► API Gateway (free https://<id>.execute-api... URL, valid certificate) ─80─► ALB
  ALB (/health check) ─80─► EC2 t3.medium (Amazon Linux 2023, configured by Ansible)
                                         └─ Docker Compose: nginx :80 → app (gunicorn+Flask) :5000 → PostgreSQL :5432
                                            + Prometheus · Alertmanager · Grafana · Jaeger · node-exporter · cAdvisor
  IAM role ─► S3 backups (nightly pg_dump) · ECR pulls      CloudWatch dashboard + alarms (ALB 5xx, unhealthy, CPU)
The same image runs on Kubernetes: kind locally (k8s/overlays/local), EKS in the playground (terraform/eks).
```

## Quick start (local)
Requirements: Docker with Compose v2, Python 3.12+, make.

```bash
make venv && source venv/bin/activate
make test              # ~110 tests: app, observability, platform files, scripts, SLO rules (promtool)
make up                # http://localhost:8080  (creates .env.local with random secrets)
make monitoring        # + Grafana http://127.0.0.1:3000 (admin / GRAFANA_ADMIN_PASSWORD in .env.local),
                       #   Prometheus :9090, Alertmanager :9093, Jaeger :16686
make kind              # the same image on a kind cluster: http://localhost:8081
```

Development server without Docker: `cp .env.example .env && make run` (SQLite, http://127.0.0.1:5000).

## API
| Endpoint | Purpose |
|---|---|
| `GET /health` | readiness: app + database (`SELECT 1`), returns the running version; 503 when the DB is down |
| `GET /livez` | liveness: the process answers (never touches the DB) |
| `GET /metrics` | Prometheus metrics (internal only: nginx 404, Ingress 403) |
| `GET/POST /api/employees`, `GET/PUT/DELETE /api/employees/<id>`, `GET /api/employees/search` | CRUD and search |
| `GET /api/departments`, `/api/departments/stats` | departments |
| `POST /api/attendance`, `GET /api/attendance/employee/<id>[/statistics]` | attendance |
| `GET /api/analytics/...` | NumPy/Pandas analytics (salary statistics, distribution, department report, ...) |
| `POST /api/validation/{email,phone,password}` | validators |
| `POST /api/alerts`, `GET /api/alerts` | Alertmanager webhook and alert history |

Every response carries `X-Request-ID`; the app writes one JSON log line per request with the same id and the trace id.

## Deploy to AWS (KodeKloud playground)
```bash
export AWS_PROFILE=<playground profile>
scripts/aws/aws-playground.sh bootstrap        # S3 state bucket + DynamoDB lock
scripts/aws/aws-playground.sh registry         # ECR + GitHub OIDC deploy role
scripts/aws/aws-playground.sh up               # VPC, EC2, ALB, IAM, S3, CloudWatch (plan shown, then applied)
scripts/aws/ecr.sh push sha-$(git rev-parse --short HEAD)
scripts/aws/aws-playground.sh deploy sha-...   # Ansible site.yml
scripts/setup-cd.sh enable                     # GitHub secrets/variables + "playground" environment
git tag v1.0.0 && git push origin v1.0.0       # CD: build → ECR → approve → deploy → smoke test → release
scripts/aws/aws-playground.sh down             # destroy everything; inventory.sh --expect-empty proves it
```
Open the app with the `https_url` output (`terraform -chdir=terraform/envs/dev output https_url`). Browsers and
phones upgrade links to `https://`, and the ALB has no certificate (a trusted one needs a domain), so the plain ALB
address only works as an explicit `http://` link. `terraform/envs/dev/https.tf` explains the choice.

Playground limits that shape the design (t3 standard credits, no inline IAM policies, 3 pods per namespace, ...) are
in `docs/aws/limits.md` and `docs/terraform/playground-quirks.md`.

## CI/CD
* **CI** (`ci.yml`, every push and PR, no secrets): flake8 + pytest with coverage · ShellCheck, yamllint, actionlint ·
  hadolint, image build, image report, Compose smoke test, Trivy · ansible-lint + syntax check ·
  terraform fmt/validate/test + playground policy check · pip-audit.
* **CD** (`cd.yml`, tag `vX.Y.Z`): image built once to `ghcr.io/<owner>/ems-app:<tag>`, the same digest copied to ECR
  (immutable tags), deploy behind the `playground` environment approval, Ansible over an SSH rule that exists only
  during the job, smoke test through the ALB, GitHub release. AWS access via OIDC: no AWS keys in GitHub.
* **Rollback** (`rollback.yml`, manual): redeploys an earlier tag; nothing is rebuilt. A deploy whose health check
  fails restores the previous tag by itself.

## Repository
| Path | Content |
|---|---|
| `app/`, `config.py`, `run.py`, `gunicorn.conf.py` | the Flask application (factory, blueprint, services, models, observability) |
| `Dockerfile`, `docker-compose.yml`, `docker-compose.monitoring.yml`, `nginx/` | image and stacks |
| `terraform/` | `bootstrap-state`, `registry`, six `modules`, `envs/dev` (applied), `envs/prod` (plan only), `eks` |
| `ansible/` | roles `common`, `docker`, `ems_stack`; playbooks `site`, `deploy`, `rollback` |
| `.github/workflows/` | CI, CD, rollback |
| `k8s/`, `k8s_samples/` | Kustomize base + overlays, monitoring; eight broken workloads to diagnose |
| `monitoring/` | Prometheus config, SLO recording rules, 15 alerts + promtool tests, Alertmanager, Grafana dashboards |
| `scripts/` | `linux/` (triage, backup, break-fix), `net/netcheck.sh`, `aws/`, `k8s/`, `chaos/`, `setup-cd.sh` |
| `docs/` | capstone plan, ADRs, linux, networking, docker, aws, terraform, kubernetes, observability, runbooks, sre |
| `tests/` | pytest for the app and for every platform file and script |

## Progress
| # | Milestone | Status |
|---|---|---|
| M1 | Baseline + capstone architecture (0-11) | done |
| M2 | Linux service and troubleshooting (12) | done (container era: triage, backups, break-fix) |
| M3 | Networking + AWS VPC (13-14) | done: netcheck PASS, VPC by Terraform |
| M4 | AWS compute + load balancing (15-16) | done: app answers through the ALB; second Ansible run `changed=0` |
| M5 | Docker + ECR (17) | done: `make up`; image in ECR, scanned on push |
| M6 | CI/CD (18-19) | done: see the Actions tab |
| M7-M8 | Terraform foundations, modules and environments (20-21) | done: dev applied, prod planned, drift check |
| M9 | Kubernetes fundamentals (22) | done on kind: 2 replicas, killed pod replaced |
| M10 | EKS + troubleshooting (23) | manifests, overlay and `terraform/eks` validated; failed rollout undone on kind |
| M11 | Observability + SRE (24-25) | done: injected failure → alert → webhook → runbook |
