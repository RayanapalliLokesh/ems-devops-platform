# Cost and cleanup

## What costs money while it exists

| Resource | Stack | Rough cost (us-east-1) | Note |
|---|---|---|---|
| ALB `ems-dev-alb` | envs/dev | ~$0.0225/h + LCUs | billed even with no traffic |
| EC2 t3.medium | envs/dev | ~$0.0416/h | standard credits: no surplus charges |
| EBS gp3 20 GB | envs/dev | ~$1.60/month | deleted with the instance |
| Public IPv4 addresses | envs/dev, eks | ~$0.005/h each | host, ALB nodes, EKS nodes |
| S3 backups, state; DynamoDB lock; ECR | all | cents | on-demand / per GB |
| CloudWatch alarms and dashboard | envs/dev | ~$0.10/alarm/month, first 3 dashboards free | |
| NAT gateway | envs/prod only (never applied) | ~$0.045/h each + $0.045/GB | the reason dev has none |
| EKS control plane | eks (not applied by default) | $0.10/h standard support, $0.60/h extended support | plus 2 nodes and the ingress NLB |

In the playground the account is free but time-limited; still, destroy everything so the session does not end with
orphaned resources and so `inventory.sh --expect-empty` proves the code owns everything it created.

## Teardown order

Reverse of creation; the state bucket goes **last**, because the other stacks keep their state in it.

```bash
# 0. only if EKS was applied: remove what Kubernetes created in AWS (NLB, EBS volumes), then the cluster
kubectl delete namespace ems monitoring ingress-nginx
terraform -chdir=terraform/eks destroy

# 1. the dev environment: host, ALB, VPC, IAM, backup bucket (force_destroy), alarms, dashboard
terraform -chdir=terraform/envs/dev destroy

# 2. ECR and the GitHub OIDC deploy role (pass the same variable as at apply time, or the role is "already gone")
terraform -chdir=terraform/registry destroy -var github_repository=<owner>/<repo>

# 3. the state bucket and lock table (local state)
terraform -chdir=terraform/bootstrap-state destroy

# 4. prove nothing is left
scripts/aws/inventory.sh --expect-empty
```

`scripts/aws/aws-playground.sh down` runs steps 1-4 with a saved destroy plan and a confirmation per stack
(`--dry-run` prints the commands).

## When a destroy gets stuck

| Symptom | Cause | Fix |
|---|---|---|
| VPC or subnet deletion times out (`DependencyViolation`) | ENIs left by something Terraform does not own: an NLB from a Kubernetes Service, a hand-made instance | delete the Kubernetes namespaces first; `aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc>` shows the owner |
| Bucket not empty | `force_destroy = false` (prod) or objects written after the last refresh | dev uses `force_destroy = true`; otherwise empty it deliberately after checking the backups are not needed |
| ECR repository not empty | images present | the registry stack sets `force_delete = true` (playground) |
| Error acquiring the state lock | a previous run crashed | make sure nothing runs, then `terraform force-unlock <id>` |
| Resource already deleted by hand | drift | `terraform plan -destroy` treats it as gone after refresh; re-run destroy |

## Verify

`scripts/aws/inventory.sh --expect-empty` lists the platform's resources (everything tagged `Project=ems`, the ECR
repository `ems-app`, IAM `ems-*`, the state bucket and the lock table) and exits 1 if any remain. Run it after
every teardown and before ending a playground session. If EKS was applied, also check that the fixed-name roles
`eksClusterRole` and `AmazonEKSNodeRole` are gone (`aws iam get-role --role-name eksClusterRole` must fail).
