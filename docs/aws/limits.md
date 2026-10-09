# KodeKloud playground limits and how this project respects them

| Limit | Effect on the design | Enforced by |
|---|---|---|
| Regions us-east-1, us-west-2, us-east-2 only | default `us-east-1` | `region` validation (dev, prod, eks); `tf_static_check.py` |
| EC2: t2/t3 nano-medium only | host t3.medium (app + monitoring need ~2.5 GB); EKS nodes t3.medium | `instance_type` validation in `modules/host`, `node_instance_type` in `eks`; static check |
| CPU credits: standard only (unlimited suspends the session) | `credit_specification { cpu_credits = "standard" }` on the host and the EKS launch template; CPU alarm + `CPUCreditBalance` on the dashboard | static check (every `aws_instance`/`aws_launch_template`); `host.tftest.hcl` |
| EBS: max 30 GB, gp2/gp3 | 20 GB encrypted gp3 everywhere | `volume_size_gb` 8-30, `node_volume_size_gb` 20-30; static check |
| Max 5 EC2 instances | 1 dev host; EKS 1-3 nodes; dev + EKS together = at most 4 | ASG max 3; static check on sizes |
| IAM: `iam:PutRolePolicy` denied | no inline policies: `aws_iam_policy` + `aws_iam_role_policy_attachment`, or AWS-managed policies | static check fails on `aws_iam_role_policy`; `tests/test_terraform.py` |
| IAM: `iam:TagPolicy` denied | policies created through provider alias `aws.untagged` (no `default_tags`) | static check |
| EKS: cluster role `eksClusterRole`, node role `AmazonEKSNodeRole` | exact names in `terraform/eks/main.tf` | `eks.tftest.hcl`, `tests/test_terraform.py` |
| EKS: max 3 nodes per node group | ASG min 1 / desired 2 / max 3 | `node_max_size` validation; static check |
| EKS: per pod max 256m CPU / 512Mi | app 250m/384Mi, postgres 250m/256Mi | `k8s/overlays/playground`, `tests/test_k8s.py` |
| EKS: max 3 pods per namespace | 2 app pods + `postgres-0`; HPA max 2; rollout `maxSurge: 0` | `k8s/overlays/playground`, `tests/test_k8s.py` |
| NAT gateways (not forbidden, but hourly + per-GB cost) | none in dev and eks: the host and the EKS nodes sit in public subnets, locked down by security groups; prod (plan only) has 2 | `nat_gateways = 0`; static check allows NAT only in `envs/prod` |
| Session expiry: the account is wiped | everything is code; state bucket recreated per session; `force_destroy` on playground buckets | `aws-playground.sh bootstrap/up/down`, `inventory.sh --expect-empty` |

Run all Terraform-side checks without an account:

```bash
python3 terraform/tf_static_check.py
terraform fmt -check -recursive terraform
./venv/bin/pytest -q tests/test_terraform.py      # also runs every terraform test suite when terraform is installed
```
