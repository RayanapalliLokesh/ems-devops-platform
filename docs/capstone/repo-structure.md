# Repository structure

One repository, one application, one history. The table shows the **final** layout and the phase in which each part
arrives. A folder that does not exist yet is not a gap: it arrives with the phase that needs it.

| Path | Content | Arrives in |
|---|---|---|
| `app/`, `config.py`, `run.py`, `requirements.txt` | the Flask application and its pinned dependencies | Phases 0-10 |
| `tests/`, `requirements-dev.txt` | pytest: application tests, and tests that run the platform scripts and parse the platform files | Phase 10, grows in every phase |
| `docs/capstone/` | target role, scope, architecture, this file, milestones; later the final review | Phase 11, Phase 30 |
| `docs/adr/` | architecture decision records | Phase 11, then one per decision |
| `docs/learning-log/` | one page per phase in your own words | Phase 11 |
| `.github/ISSUE_TEMPLATE/`, `.github/pull_request_template.md` | the same structure for every phase | Phase 11 |
| `Makefile`, `CHANGELOG.md` | developer shortcuts; one entry per phase | Phase 11 |
| `gunicorn.conf.py`, `scripts/linux/`, `docs/linux/` | the application as a Linux service; administration and troubleshooting tools | Phase 12 |
| `nginx/`, `scripts/net/`, `docs/networking/` | reverse proxy, network checks, port map, request flow | Phase 13 |
| `scripts/aws/`, `docs/aws/` | AWS CLI scripts; architecture, limits and decisions | Phase 14 |
| `deploy/aws/` | first-boot script of the EC2 host | Phase 15 |
| `ansible/` | roles, playbooks, inventories | Phase 16 |
| `Dockerfile`, `docker-compose.yml`, `docs/docker/` | image, stack, image review and runtime troubleshooting | Phase 17 |
| `.github/workflows/` | CI, CD and rollback workflows | Phases 18-19 |
| `terraform/`, `docs/terraform/` | remote state and registry, the host platform, then modules and environments, then EKS | Phases 20, 21, 23 |
| `k8s/`, `docs/kubernetes/` | Kustomize base and overlays, object guide, troubleshooting guide | Phases 22-23 |
| `k8s_samples/` | broken workloads to practise on | Phase 23 |
| `monitoring/`, `docker-compose.monitoring.yml`, `docs/observability/` | Prometheus, Alertmanager, Grafana, Jaeger; metrics, logs and traces explained | Phase 24 |
| `docs/runbooks/`, `docs/sre/`, `scripts/chaos/` | one runbook per alert, SLOs, game days | Phase 25 |
| `app/ai/` | AI-assisted operations | Phases 26-29 |
| `skills/`, `knowledge_base/` | what the AI teammate knows about this platform | Phase 28 |
| `docs/career/` | resume bullets, GitHub checklist, interview questions, job plan | Phase 30 |

Two folders exist only for a while: `deploy/linux/` (Phases 12 to 15, replaced by Ansible templates) and the AWS
CLI scripts that create resources (Phases 14 to 19, replaced by Terraform). The table lists what the finished
repository contains. `tests/test_capstone_plan.py` compares it with the working tree in every phase: a path must
exist from its phase on, and must not exist before it.

## Rules
* **`main` always works.** Nothing is committed to it directly; each phase arrives through one pull request.
* **Nothing secret is committed.** `.env`, keys, Terraform state and generated inventories are in `.gitignore`.
  The `.env` file that earlier phases kept in the folder is removed in this phase; `.env.example` is the template.
* **A later phase removes what it replaces.** The earlier tag still has the old files.
* **Every script supports a dry run or runs in a temporary folder**, so the tests can execute it without root, a
  cloud account or a cluster.
* **Documentation lives next to the code** and is checked by tests where a check is possible (for example: every
  listening port must appear in the port map).

## Naming
| Thing | Pattern | Example |
|---|---|---|
| Branch | `phase/NN-short-name` | `phase/12-linux-service` |
| Commit | Conventional Commits | `feat(linux): add systemd unit for gunicorn` |
| Tag | `phase-NN` (annotated); version tags `vX.Y.Z` from Phase 19 | `phase-12`, `v1.0.0` |
| AWS resource | `ems-<kind>`, tag `Project=ems` | `ems-vpc`, `ems-alb` |
| Terraform environment | `terraform/envs/<name>` | `terraform/envs/dev` |
