# Variables and outputs (Phase 20)

Inputs are typed and validated so a wrong value fails at `plan`, before anything is created in AWS. Outputs are the
only thing other tools (Ansible, scripts, CD, people) read from Terraform: nobody parses the state.

## Variables of `envs/dev`

| Variable | Type | Default | Validation / note |
|---|---|---|---|
| `region` | string | `us-east-1` | must be one of the playground regions `us-east-1`, `us-west-2`, `us-east-2` |
| `environment` | string | `dev` | prefix of every name: `ems-dev-*` |
| `vpc_cidr` | string | `10.0.0.0/16` | subnets derived with `cidrsubnet(vpc_cidr, 8, n)`: 1, 2 public; 11, 12 private |
| `instance_type` | string | `t3.medium` | the host module accepts only t2/t3 nano-medium |
| `ssh_cidrs` | list(string) | **required** | admin IP `/32`; `0.0.0.0/0` is rejected by the security_groups module |
| `ssh_public_key` | string | **required** | public half of the CD deploy key |
| `ecr_repository_name` | string | `ems-app` | read with a data source; the repository belongs to `terraform/registry` |

Values come from `terraform.tfvars` (gitignored; `aws-playground.sh up` writes it with the current public IP).
`terraform.tfvars.example` documents the shape.

## Validation inside the modules

| Module | Variable | Rule |
|---|---|---|
| network | `azs` | at least 2 (the ALB needs two zones) |
| network | `nat_gateways` | 0, 1 or 2 |
| network | `cidr` | a valid CIDR |
| security_groups | `ssh_cidrs` | valid CIDRs, never `0.0.0.0/0` |
| host | `instance_type` | t2/t3 nano, micro, small, medium |
| host | `volume_size_gb` | 8-30 GB |
| load_balancer | `subnet_ids` | at least 2 |
| eks | `node_instance_type`, `node_max_size`, `node_volume_size_gb` | t2/t3 nano-medium, 1-3 nodes, 20-30 GB |

The same limits are enforced across all files by `terraform/tf_static_check.py`, and exercised by the
`terraform test` suites (`expect_failures` proves that a bad value is rejected).

## Outputs of `envs/dev`

| Output | Used by |
|---|---|
| `alb_dns_name`, `app_url` | smoke tests, people, the CD workflow |
| `host_public_ip`, `host_instance_id` | SSH, CloudWatch, chaos scripts |
| `host_security_group_id` | CD opens/closes the temporary SSH rule on it |
| `backup_bucket` | Ansible backup timer |
| `ecr_repository_url` | image pushes, Ansible |
| `vpc_id` | inventory and cleanup checks |

```bash
terraform -chdir=terraform/envs/dev output              # all
terraform -chdir=terraform/envs/dev output -raw app_url # one value for scripts
```

## The Ansible inventory: an output written to a file

`envs/dev` also renders `ansible/inventories/aws/hosts.yml` with `local_file` + `yamlencode`: host address, image,
region, backup bucket, ALB name. That file is the whole contract between Terraform and Ansible - Terraform decides
*where*, Ansible decides *what runs there*.

## Module outputs

Modules expose IDs, not whole objects (`vpc_id`, `public_subnet_ids`, `host_sg_id`, `instance_profile_name`,
`target_group_arn_suffix`, ...). An environment wires modules together only through these outputs, which keeps each
module testable on its own with a mock provider.
