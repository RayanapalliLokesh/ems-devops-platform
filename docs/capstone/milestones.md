# Milestones

Twelve milestones, one per focus area. A milestone is **done** when its exit check passes and its tags exist. Write
the date next to each one as you finish it; the table becomes the progress section of your README.

| # | Focus | Phases | Expected output | Exit check | Tags |
|---|---|---|---|---|---|
| M1 | Baseline + capstone architecture | 0-11 | target role, project scope, repository structure, first milestones | `make test` passes (20 tests); `docs/capstone/` is complete | `phase-00` ... `phase-11` |
| M2 | Linux troubleshooting review | 12 | processes, logs, services, storage, shell scenarios | the service survives a reboot; all five break-and-fix scenarios are solved | `phase-12` |
| M3 | Networking + AWS VPC | 13-14 | request flow; VPC, subnets, routes, NAT, DNS, security groups | `netcheck.sh` prints only PASS; the network of `docs/aws/architecture.md` is drawn from memory and explained | `phase-13`, `phase-14` |
| M4 | AWS compute + load balancing | 15-16 | EC2, ALB, IAM, security and HA decisions | the application answers through the load balancer; the second Ansible run reports `changed=0` | `phase-15`, `phase-16` |
| M5 | Docker + ECR | 17 | Dockerfile review, image optimisation, runtime troubleshooting | `make up` starts the stack; the image is in ECR and scanned | `phase-17` |
| M6 | CI/CD | 18-19 | pipeline design; build, test, scan, deploy and rollback | CI is green on a pull request; a tag is deployed and rolled back | `phase-18`, `phase-19`, `v1.0.0` |
| M7 | Terraform foundations | 20 | state, backend, variables, outputs, drift | `plan` after `apply` shows no changes; a manual change is detected as drift | `phase-20` |
| M8 | Terraform modules + environments | 21 | reusable IaC, dev/prod separation, review | the refactoring plan destroys no cloud resource; the `prod` plan is reviewed with the checklist | `phase-21` |
| M9 | Kubernetes fundamentals | 22 | Deployments, Services, ConfigMaps, Secrets, probes | two replicas answer on kind; a killed pod is replaced | `phase-22` |
| M10 | EKS + troubleshooting | 23 | Ingress, scaling, failures, rollout and rollback | a failed rollout is undone; every broken workload in `k8s_samples/` is diagnosed | `phase-23` |
| M11 | Observability + SRE | 24-25 | metrics, logs, traces, alerting, SLO thinking | an injected failure fires an alert that links to a runbook | `phase-24`, `phase-25` |
| M12 | Capstone + interviews | 26-30 | final review, resume, GitHub, mock interview, job plan | `scripts/capstone-check.sh` prints no FAIL; one mock interview is recorded | `phase-26` ... `phase-30`, `v2.0.0` |

## First milestones in detail
The first three milestones are planned to the task level now. Later milestones are planned when the previous one
is finished, because by then you know what the platform really looks like.

### M1 - Baseline (this phase)
- [ ] `.env` removed from the repository, `.env.example` kept
- [ ] `docs/capstone/`: target role, scope, architecture, repository structure, milestones
- [ ] `docs/adr/0001-flask.md`, `0002-dual-version.md`
- [ ] issue and pull request templates, `CHANGELOG.md`, `Makefile`
- [ ] pull request merged with a merge commit, tag `phase-11`

### M2 - Linux service and troubleshooting (Phase 12)
- [ ] gunicorn runs as the systemd unit `ems` under its own user and restarts after a failure
- [ ] PostgreSQL replaces the SQLite file
- [ ] a release can be deployed and rolled back; a backup can be restored
- [ ] `triage.sh` answers "what is wrong with this server?" in one screen
- [ ] five scenarios broken and fixed, each with a note in the learning log

### M3 - Network (Phases 13-14)
- [ ] nginx is the only listener other machines can reach
- [ ] the port map lists every listening port and a test enforces it
- [ ] the VPC, four subnets, two route tables and two security groups exist and are removed again
- [ ] you can draw the request path from memory

## How to record progress
Open one GitHub issue per phase from the template, link the pull request to it, and close it with the merge. The
closed issues, the merged pull requests and the tags tell the same story from three sides.
