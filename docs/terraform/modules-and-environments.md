# Modules and environments (Phase 21)

```
terraform/modules/                       terraform/envs/
  network          VPC, 2+2 subnets,       dev   applied in the playground
                   IGW, routes, NAT?       prod  planned only (never applied)
  security_groups  alb + host groups     terraform/eks    reuses modules/network (Phase 23)
  backup_bucket    S3 for pg_dump        terraform/registry, terraform/bootstrap-state: one-off stacks
  host_role        IAM role + profile
  host             EC2 + alarms
  load_balancer    ALB + TG + alarms
```

Every module has the same four files: `main.tf` (resources), `variables.tf` (typed, validated inputs),
`outputs.tf` (IDs for the caller), `versions.tf` (Terraform and provider constraints). Modules never configure a
provider themselves; `host_role` declares `configuration_aliases = [aws.untagged]` and receives it from the
environment (see [playground-quirks.md](playground-quirks.md)).

## dev vs prod: same modules, different values

| | dev (`envs/dev`) | prod (`envs/prod`) |
|---|---|---|
| Applied? | yes, in the KodeKloud playground | **plan only** |
| Host subnet | public (`public_subnet_ids[0]`) | private (`private_subnet_ids[0]`) |
| Public IP | yes (`public_ip = true`) | no |
| NAT gateways | `0` (cost; the host is public anyway) | `2`, one per zone, so a zone failure does not cut the other zone off |
| SSH | from the admin IP only (`ssh_cidrs = ["<ip>/32"]`), key pair from `ssh_public_key` | none (`ssh_cidrs = []`, no key pair): deploys through SSM Session Manager or a bastion |
| Backup bucket `force_destroy` | `true` (the playground is wiped anyway) | `false` (a destroy must not delete backups) |
| Ansible inventory | `hosts.yml`, public IP | `hosts-prod.yml`, private IP |
| Instance type | t3.medium | t3.medium (same size; production would size up) |
| State key | `envs/dev/terraform.tfstate` | `envs/prod/terraform.tfstate` |

The differences live in the environment's `main.tf` arguments, not in copies of resources. A fix in a module
reaches both environments. `tests/test_terraform.py` asserts that both environments use the same set of modules and
that prod keeps `nat_gateways = 2` and `ssh_cidrs = []`.

Why prod is not applied: NAT gateways cost money per hour and per GB, a private host needs SSM/bastion access that
the playground does not provide, and the playground allows few instances. The plan still proves the code is
complete and valid for a production shape.

## Why there is no `moved.tf`

`moved` blocks tell Terraform that a resource changed address (`aws_vpc.main` -> `module.network.aws_vpc.this`)
so that a refactor into modules renames state entries instead of destroying and recreating real infrastructure.
They are needed when a flat configuration that is **already applied** gets split into modules.

This project's Terraform used the modules from its first apply: `envs/dev` was created with
`module.network`, `module.host`, ... addresses from the start (Phase 14-15 resources were built with the AWS CLI,
destroyed, and then recreated by Terraform, not imported). No state ever held the flat addresses, so there was
nothing to move. If a module is later renamed or a resource is moved between modules, add a `moved` block in the
same commit and check that the plan shows `has moved to` and no destroy:

```hcl
moved {
  from = module.host.aws_instance.this
  to   = module.app_host.aws_instance.this
}
```

## Tests

| Suite | Checks |
|---|---|
| `modules/network/tests/network.tftest.hcl` | 2 public + 2 private subnets with the right CIDRs, 0 NAT by default, 2 NAT + routes with `nat_gateways = 2`, one AZ rejected |
| `modules/security_groups/tests/sg.tftest.hcl` | no SSH rule when `ssh_cidrs` is empty, one rule per CIDR, `0.0.0.0/0` rejected |
| `modules/host/tests/host.tftest.hcl` | standard CPU credits, IMDSv2 required, encrypted gp3, t3.large and 40 GB rejected (AMI data source overridden) |
| `modules/host_role/tests/host_role.tftest.hcl` | role, managed policy (through the mocked `aws.untagged` alias), instance profile |
| `envs/dev/tests/dev.tftest.hcl` | the whole dev wiring: no NAT, two AZs, outputs and the Ansible inventory after a mock apply, region validation |
| `eks/tests/eks.tftest.hcl` | role names, no NAT, node launch template and ASG limits |

All of them use `mock_provider "aws"`: no AWS account, no credentials, nothing created. Run one with
`terraform -chdir=terraform/modules/network init -backend=false && terraform -chdir=terraform/modules/network test`;
CI runs them all, and `tests/test_terraform.py` runs them under pytest when `terraform` is installed.
