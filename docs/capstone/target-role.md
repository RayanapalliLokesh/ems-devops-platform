# Target role

This project is built to be shown to an interviewer. Before the first platform phase, decide **which job** it is
evidence for. Every later decision (what to build, how deep, what to skip) is measured against that answer.

## The role
**DevOps / Site Reliability Engineer, junior to mid level** (also advertised as Cloud Engineer, Platform Engineer or
Infrastructure Engineer). In one sentence: *the person who makes sure a change reaches production safely, and that
production keeps working afterwards.*

## What the job asks for, and where this project proves it
| # | Skill a job description asks for | Focus area of this project | Evidence you will be able to show |
|---|---|---|---|
| 1 | Reads an architecture and plans work in milestones | Baseline + capstone architecture (Phases 0-11) | `docs/capstone/`, ADRs, a tagged baseline with 20 passing tests |
| 2 | Finds out why a Linux server misbehaves | Linux troubleshooting (Phase 12) | systemd service, releases with rollback, `triage.sh`, five break-and-fix scenarios |
| 3 | Explains how a request travels and designs a network | Networking + AWS VPC (Phases 13-14) | nginx reverse proxy, `netcheck.sh`, a VPC with public and private subnets, routes and security groups |
| 4 | Runs compute behind a load balancer, with least privilege | AWS compute + load balancing (Phases 15-16) | EC2 behind an Application Load Balancer, an IAM instance profile, Ansible roles, a written HA decision |
| 5 | Builds small, safe container images | Docker + ECR (Phase 17) | multi-stage non-root image, Compose stack, image pushed to ECR and scanned |
| 6 | Designs a pipeline with gates and a way back | CI/CD (Phases 18-19) | GitHub Actions: build, test, scan, deploy behind an approval, one-click rollback |
| 7 | Manages infrastructure as code and its state | Terraform foundations (Phase 20) | remote state with locking, variables with validation, outputs, a drift report |
| 8 | Writes reusable IaC for several environments | Terraform modules + environments (Phase 21) | one set of modules, `dev` and `prod` environments, a review checklist |
| 9 | Deploys and configures workloads on Kubernetes | Kubernetes fundamentals (Phase 22) | Deployment, Service, ConfigMap, Secret and three probes on a kind cluster |
| 10 | Operates a managed cluster and debugs failures | EKS + troubleshooting (Phase 23) | Ingress, autoscaling, rollout and rollback, broken workloads diagnosed and fixed |
| 11 | Knows whether the service is healthy, and when to page | Observability + SRE (Phases 24-25) | metrics, structured logs, traces, alert rules, SLOs, runbooks, game days |
| 12 | Presents the work and answers questions about it | Capstone + interviews (Phases 26-30) | AI-assisted operations, final review, resume bullets, mock interview answers |

## What an interviewer will ask about it
* "Walk me through a request, from the browser to the database." (Phases 13 to 15)
* "The service is down. What do you type first?" (Phases 12, 17, 23)
* "How does a commit reach production, and how do you undo it?" (Phases 18, 19)
* "Where is your Terraform state and what happens when two people apply at once?" (Phase 20)
* "What is the difference between a liveness and a readiness probe? Show me yours." (Phase 22)
* "Which alert wakes you up at night, and why that one?" (Phases 24, 25)

Every one of these has a file in this repository that answers it. `docs/career/` (Phase 30) turns the files into
spoken answers.

## Not the target
Application development (the Flask code is deliberately simple), data engineering, and multi-cloud breadth: one
cloud, AWS, used in depth.
