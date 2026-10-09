# KodeKloud playground quirks and the fixes

The playground is a real AWS account with a restrictive policy. Each item below cost a failed apply once.

## `iam:PutRolePolicy` is denied: no inline role policies

`aws_iam_role_policy` fails with `AccessDenied ... iam:PutRolePolicy`.

**Fix:** a customer-managed policy plus an attachment, or an AWS-managed policy attachment:

```hcl
resource "aws_iam_policy" "host" {
  provider = aws.untagged
  name     = "${var.name}-host-policy"
  policy   = data.aws_iam_policy_document.host.json
}

resource "aws_iam_role_policy_attachment" "host" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.host.arn
}
```

`terraform/eks` needs no custom policy at all: the cluster and node roles use only AWS-managed policies
(`AmazonEKSClusterPolicy`, `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`,
`AmazonEC2ContainerRegistryReadOnly`, optional `AmazonEBSCSIDriverPolicy`).

## `iam:TagPolicy` is denied: create policies through an untagged provider alias

The provider's `default_tags` tag every resource, including `aws_iam_policy` - and tagging a policy is denied, so
the create fails even though `iam:CreatePolicy` is allowed.

**Fix:** a second provider configuration without `default_tags`, used only for IAM policies:

```hcl
provider "aws" {
  alias  = "untagged"
  region = var.region
}

module "host_role" {
  source    = "../../modules/host_role"
  providers = { aws = aws, aws.untagged = aws.untagged }
  ...
}
```

The module declares `configuration_aliases = [aws.untagged]` in `versions.tf`. In `terraform test` the alias needs
its own `mock_provider "aws" { alias = "untagged" }`. `tf_static_check.py` fails any `aws_iam_policy` without
`provider = aws.untagged`, and any `aws_iam_role_policy`.

Roles (`iam:TagRole`) and instance profiles can be tagged; only policies cannot.

## `for_each` keys must be known at plan time

`for_each = toset([module.host.instance_id])` fails on the first plan: *"The for_each value depends on resource
attributes that cannot be determined until apply"* - the instance ID does not exist yet, and Terraform needs the
keys to name the resources (`aws_lb_target_group_attachment.this["i-..."]`).

**Fix:** a map with **static keys** and unknown values: `target_instance_ids = { host = module.host.instance_id }`.
The key (`host`) is known at plan time, the value is filled in at apply. The same idea in `terraform/eks`: the node
role's policy attachments use `for_each` over a map with fixed keys (`worker`, `cni`, `ecr`, `ebs_csi`).

## CPU credits must be `standard`

t2/t3 in `unlimited` mode (the default for t3 in many accounts) can bill CPU surplus; the playground suspends the
session when it sees it.

**Fix:** always set it explicitly, on instances and on launch templates:

```hcl
credit_specification {
  cpu_credits = "standard"
}
```

Consequence: a busy t3 runs out of credits and is throttled to its baseline (20% for t3.small, 20% x 2 vCPU for
t3.medium). The dashboard shows `CPUCreditBalance`; the runbook `HostHighCPU.md` explains it.

## Other limits applied in code

| Limit | Where enforced |
|---|---|
| Regions us-east-1, us-west-2, us-east-2 | `region` validation in every environment; static check |
| t2/t3 nano-medium, max 5 instances | `host` / `eks` variable validation; static check |
| EBS max 30 GB (gp2/gp3) | `volume_size_gb` validation (8-30); static check |
| No NAT in what we apply | `nat_gateways = 0` in dev and eks; static check (prod exempt: plan only) |
| EKS role names `eksClusterRole` / `AmazonEKSNodeRole`, max 3 nodes per group | `terraform/eks`; `tests/test_terraform.py`; static check |

## `dynamodb_table` is deprecated (Terraform >= 1.10)

From Terraform 1.10 the S3 backend can lock with a lock object in the bucket itself, and `dynamodb_table` prints a
deprecation warning:

```
Warning: Deprecated Parameter
  The parameter "dynamodb_table" is deprecated. Use parameter "use_lockfile" instead.
```

It still works, and CI pins Terraform 1.9.8, which does not know `use_lockfile`, so this project keeps the DynamoDB
table. The alternative once every user and CI is on >= 1.10:

```hcl
bucket       = "ems-tfstate-123456789012"
region       = "us-east-1"
use_lockfile = true    # writes envs/dev/terraform.tfstate.tflock next to the state (needs s3:PutObject/DeleteObject on it)
encrypt      = true
```

During a migration both can be set at once (Terraform takes both locks); then drop `dynamodb_table` and delete the
`ems-tf-locks` table from `bootstrap-state`.

## Sessions expire

Everything in the account is deleted when the playground session ends - including the state bucket. Treat each
session as a fresh account: `bootstrap` -> `registry` -> `up`, and destroy before the timer runs out so the state
and reality do not diverge (see [../aws/cost-and-cleanup.md](../aws/cost-and-cleanup.md)).
