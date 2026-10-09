# Changelog (from Phase 11)

## Phase 25 - SRE practice
Two SLOs over 7 days (99.5 % without 5xx, 95 % under 500 ms) as recording rules; multi-window burn-rate alerts
(fast 14.4x pages, slow 6x tickets) tested with `promtool test rules`; one runbook per alert (15, enforced by
`tests/test_sre.py`); error-budget policy, on-call, incident and postmortem templates; game days with six chaos
scripts in `scripts/chaos/` (high CPU, DB timeout, DNS failure, image-pull failure, LB health-check failure,
Terraform drift). ADR 0007.

## Phase 24 - Observability
`/metrics` (RED histograms per URL rule, `ems_db_up`, gunicorn multi-process mode), one JSON log line per request
with `request_id` and `trace_id`, `X-Request-ID` from nginx, OpenTelemetry traces to Jaeger (request and SQL spans).
`docker-compose.monitoring.yml`: Prometheus, Alertmanager (webhook to `POST /api/alerts`, history at
`GET /api/alerts`), Grafana (RED and USE dashboards), node-exporter, cAdvisor, Jaeger. Kubernetes monitoring in
`k8s/monitoring/`. CloudWatch dashboard and alarms on the ALB and EC2 (Terraform). `/metrics` is never public
(nginx and Ingress answer 404/403).

## Phase 23 - EKS and troubleshooting
Ingress (ingress-nginx), HPA, `playground` overlay sized for 3 pods per namespace with images from ECR,
`terraform/eks` (network module, `eksClusterRole`/`AmazonEKSNodeRole`, self-managed AL2023 nodes; validated, not
applied), eight broken workloads in `k8s_samples/` with `k8s-triage.sh`.

## Phase 22 - Kubernetes on kind
Kustomize base and `local` overlay: Deployment (2 replicas, `/livez` liveness, `/health` readiness, non-root,
read-only root file system), Service, PostgreSQL StatefulSet with PVC, ConfigMap from `config.env`, Secret,
NetworkPolicy (only the app reaches PostgreSQL). `k8s-up.sh`, `k8s-rollout.sh` (automatic undo).

## Phase 21 - Terraform modules and environments
Six modules (`network`, `security_groups`, `backup_bucket`, `host_role`, `host`, `load_balancer`), `envs/dev`
(applied in the playground) and `envs/prod` (private host, NAT per zone, no SSH; planned only), `terraform test`
with mock providers, `tf_static_check.py` for the playground limits.

## Phase 20 - Terraform
`bootstrap-state` (S3 + DynamoDB lock), `registry` (ECR, immutable tags, scan on push; GitHub OIDC deploy role),
the dev platform with outputs and a generated Ansible inventory, drift detection (`aws-playground.sh drift`).
Replaces the AWS CLI scripts that created resources; `scripts/aws/` keeps the read-only and helper scripts. ADR 0004.

## Phase 19 - CD and rollback
`cd.yml`: a `vX.Y.Z` tag builds once to ghcr.io, copies the same digest to ECR, waits for approval (environment
`playground`), deploys with Ansible over a temporary SSH rule, smoke-tests through the ALB and creates a GitHub
release. `rollback.yml` deploys an earlier tag. `scripts/setup-cd.sh`. ADRs 0005, 0006.

## Phase 18 - CI
`ci.yml`: lint-and-test, scripts-and-yaml (ShellCheck, yamllint, actionlint), docker (hadolint, build, image
report, Compose smoke test, Trivy), ansible (ansible-lint, syntax check), terraform (fmt, validate, test, static
check), security (pip-audit). No secrets.

## Phase 17 - Docker and ECR
Multi-stage `Dockerfile` (python:3.12-slim, user 10001, HEALTHCHECK), `docker-compose.yml` (db -> app -> nginx,
each waits for the previous one to be healthy; read-only app container), ECR. Ansible roles `docker` and
`ems_stack` replace the host services (`retire.yml`). psycopg 3 and SQLAlchemy 2.1 pinned. ADR 0003.

## Phase 16 - Ansible
Roles `common`, `docker`, `ems_stack`; playbooks `site.yml`, `deploy.yml` (automatic restore of the previous tag
when the health check fails), `rollback.yml`; inventories `local` and `aws` (generated). Second run: `changed=0`.

## Phase 15 - EC2, ALB and IAM
EC2 host (Amazon Linux 2023, t3 standard credits, IMDSv2, encrypted gp3) behind an ALB with a `/health` target
check; IAM role and instance profile for S3 backups and ECR pulls without keys; first-boot script `deploy/aws/user-data.sh`.

## Phase 14 - AWS VPC
VPC with two public and two private subnets, internet gateway, route tables, security groups (ALB: 80 from
anywhere; host: 80 from the ALB only, 22 from the admin IP); `scripts/aws/inventory.sh --expect-empty`.

## Phase 13 - Networking
nginx reverse proxy as the only public listener (`X-Forwarded-For`, `X-Request-ID`, re-resolving upstream),
`TRUSTED_PROXIES` (ProxyFix), `scripts/net/netcheck.sh`, port map with a test that enforces it.

## Phase 12 - Linux service
gunicorn configuration, PostgreSQL instead of SQLite, `/livez`, backups (`backup-db.sh`), `triage.sh`,
`break-fix.sh` with five scenarios, Linux docs.

## Phase 11 - Baseline and capstone architecture
The application of Phase 10 is frozen as the baseline. Capstone plan in `docs/capstone/` (target role, scope,
architecture, repository structure, milestones), the first two architecture decision records, issue and pull
request templates, learning log, Makefile. The committed `.env` is removed.
