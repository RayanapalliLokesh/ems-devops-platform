# Reviewing a prod plan

A plan is the change request. Review the **saved plan** that will be applied, not a fresh one:

```bash
terraform -chdir=terraform/envs/prod plan -input=false -out=tfplan
terraform -chdir=terraform/envs/prod show tfplan                 # human readable
terraform -chdir=terraform/envs/prod show -json tfplan > plan.json
jq -r '.resource_changes[] | select(.change.actions != ["no-op"]) | "\(.change.actions|join(",")) \(.address)"' plan.json
```

## Before reading the diff

- [ ] The plan was made from the reviewed commit (clean `git status`, the PR's head SHA).
- [ ] Right account and region (`aws sts get-caller-identity`, `region` in the plan), right state key
      (`envs/prod/terraform.tfstate`), backend initialised with `-reconfigure -backend-config=...`.
- [ ] CI is green for that commit: `terraform fmt -check`, `validate`, `terraform test`, `tf_static_check.py`.
- [ ] The summary line (`Plan: X to add, Y to change, Z to destroy`) matches what the PR description says.

## Destroys and replacements (stop here first)

- [ ] Every `-/+` (replace) and `-` (destroy) is explained in the PR. Look for `forces replacement` next to an
      attribute: on `aws_instance` that means a new host (new IP, data on the root volume gone), on `aws_lb` a new
      DNS name, on `aws_s3_bucket` or `aws_dynamodb_table` lost data.
- [ ] A refactor shows `has moved to` (a `moved` block), not destroy + create.
- [ ] Nothing stateful is destroyed: backup bucket, ECR repository, state bucket, lock table.
- [ ] `force_destroy` is still `false` on the prod backup bucket.

## Security

- [ ] No security group rule opens `0.0.0.0/0` except ALB port 80 (443 later). No SSH rule in prod (`ssh_cidrs = []`).
- [ ] The host stays in a private subnet with `associate_public_ip_address = false`.
- [ ] IAM: policies are least-privilege (resource ARNs, not `*`, except `ecr:GetAuthorizationToken`), no new
      `aws_iam_role_policy` (inline), trust policies name the expected principal (EC2, EKS, GitHub repo `sub`).
- [ ] Encryption stays on: EBS `encrypted = true`, S3 SSE, IMDSv2 `http_tokens = required`.
- [ ] No secret in the plan output (user data, variables); sensitive values show as `(sensitive value)`.

## Availability and cost

- [ ] Two NAT gateways (one per zone) and private routes pointing at the NAT in the same zone.
- [ ] ALB in two public subnets; health check path `/health`.
- [ ] Instance type, volume size and counts as intended; t2/t3 with `cpu_credits = "standard"`.
- [ ] New hourly-billed resources (NAT, ALB, EKS, EIPs) are expected and budgeted.

## Operations

- [ ] Alarms are not removed or renamed silently (dashboards and runbooks reference the names).
- [ ] Tags (`Project`, `Environment`, `ManagedBy`) present through `default_tags`.
- [ ] Rollback plan: how to undo (revert commit + plan/apply, or restore from backup) and how long it takes.
- [ ] Apply exactly the reviewed file: `terraform apply tfplan` (a stale plan is refused by Terraform).
- [ ] After apply: `plan -detailed-exitcode` returns 0, smoke test through the ALB passes.
