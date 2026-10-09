# Project scope

## One sentence
One Employee Management System (a Flask REST API with a database) is carried through every layer a DevOps
engineer works with, in twelve focus areas, in **one Git repository** whose history shows the work.

## In scope
| Area | What is built | What is deliberately left out |
|---|---|---|
| Application | REST API, SQLAlchemy models, analytics, tests, logging, configuration from the environment | a user interface, migrations with Alembic |
| Linux | service user, systemd unit and timer, PostgreSQL, releases with rollback, backups, log rotation, troubleshooting tools | configuration of a mail server, LDAP, SELinux policies |
| Network | bind addresses, ports, name resolution, nginx reverse proxy, host firewall | TLS certificates and a public domain name (documented as the next step) |
| AWS | VPC with public and private subnets, routes, security groups, EC2, Application Load Balancer, IAM instance profile, S3, ECR, EKS | RDS, Route 53, CloudFront, multi-region |
| Configuration | Ansible roles and inventories for the local machine and the EC2 host | Ansible Tower / AWX, dynamic inventory plugins |
| Containers | image, Compose stack, registry (ECR and ghcr.io) | Docker Swarm, image signing |
| Pipeline | CI with lint, tests and scans; CD with an approval gate; rollback | self-hosted runners, multi-stage promotion across accounts |
| IaC | Terraform state, backend, variables, outputs, drift, modules, `dev` and `prod` | Terragrunt, Terraform Cloud, Sentinel |
| Kubernetes | kind and EKS: Deployments, Services, ConfigMaps, Secrets, probes, Ingress, autoscaling, rollouts | Helm charts, service mesh, GitOps controllers |
| Observability | Prometheus, Alertmanager, Grafana, structured logs, traces, SLOs, runbooks, game days | a log database, a paid APM product |
| AI operations | read-only agents for Kubernetes, cost, platform knowledge and root cause analysis; offline by default | agents that change the system |

## Two versions from one codebase
| | Full Local version | Playground version |
|---|---|---|
| Where | one Ubuntu 22.04 or 24.04 machine (a virtual machine is ideal) | the KodeKloud AWS playground, or your own AWS account |
| Cost | none | none inside a playground session; resources disappear with it |
| Rule | **everything must work here** | proves the same code on real cloud infrastructure, inside the playground limits |

The decision is recorded in `docs/adr/0002-dual-version.md`.

## Constraints that shape the design
| Constraint | Consequence |
|---|---|
| Playground sessions last a few hours and are wiped | every cloud script can build and remove its resources quickly; all work lives in Git |
| Regions us-east-1, us-east-2, us-west-2; EC2 t2/t3 up to medium; EBS up to 30 GB | the limits are checked by the scripts and by the Terraform static checker |
| NAT gateways are not available in the playground | the playground network has no NAT; the `prod` environment declares one |
| Custom IAM roles may be denied | the instance profile is optional and every script works without it |
| EKS: no managed node groups, 3 pods per namespace, 256m CPU / 512Mi per pod | self-managed nodes and a reduced overlay |
| No secrets in Git | secrets are generated at deploy time; `.env` is ignored and no longer committed from this phase |

## Definition of done for a phase
1. The work is on a branch `phase/NN-short-name`, in small commits with Conventional Commit messages.
2. `make test` passes; from Phase 18 the CI workflow is green.
3. The phase `README.md` says what was added, how to run it and what was verified.
4. A pull request with evidence is merged with a merge commit, tagged `phase-NN`, and released with a learning log.
