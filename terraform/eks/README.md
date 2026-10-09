# terraform/eks - EKS in the KodeKloud playground (Phase 23)

```
EKS:  NLB :80 -> NodePort -> ingress-nginx -> Service ems-app -> pods (1-2) on self-managed nodes (ASG)

module "network" (phase 21, nat_gateways = 0)       10.1.0.0/16, public 10.1.1.0/24 + 10.1.2.0/24
aws_eks_cluster "ems" (role eksClusterRole)          API_AND_CONFIG_MAP, public + private endpoint
aws_eks_access_entry (AmazonEKSNodeRole, EC2_LINUX)  lets the nodes join without editing aws-auth
aws_launch_template + aws_autoscaling_group          AL2023 EKS AMI, t3.medium, standard credits, 20 GB gp3,
                                                     IMDSv2 hop limit 2, nodeadm user data, min 1 / desired 2 / max 3
```

> **Cost and time warning.** This configuration is **not applied by default**. Creating the control plane
> takes ~10-15 minutes and destroying it another ~10. The EKS control plane is billed per hour (about
> $0.10/h in standard support, **$0.60/h once the Kubernetes version is in extended support**: check that
> `kubernetes_version` is still in standard support, and pass a newer one with `-var kubernetes_version=1.xx`
> if not), plus two t3.medium nodes and the NLB the ingress controller creates. In the playground the
> session ends after a few hours; destroy before it does or the account is wiped with the cluster in it.

## Why it looks like this

| Choice | Reason |
|---|---|
| Role names `eksClusterRole`, `AmazonEKSNodeRole` | the playground only allows EKS roles with these exact names |
| AWS-managed policy **attachments** only | `iam:PutRolePolicy` (inline policies) and `iam:TagPolicy` are denied |
| Self-managed nodes (launch template + ASG) instead of a managed node group | the node group is visible as plain EC2 + ASG, and every playground limit (type, credits, volume, count) is set explicitly |
| Nodes in **public** subnets with public IPs | no NAT gateway in the playground: nodes need a public IP to reach ECR and the EKS API. The node security group allows nothing from the internet except what the load balancer controller opens for NodePorts |
| `credit_specification { cpu_credits = "standard" }` | unlimited credits suspend the playground session |
| max 3 nodes, t2/t3 nano-medium, <= 30 GB volume | playground limits, validated in `variables.tf` and by `terraform/tf_static_check.py` |
| VPC 10.1.0.0/16 | can exist next to `envs/dev` (10.0.0.0/16). Together: 1 dev host + up to 3 nodes = 4 instances (playground max 5) |
| `AmazonEBSCSIDriverPolicy` on the node role (`ebs_csi_node_policy`) | `postgres-0` needs an EBS volume; without IRSA the EBS CSI driver uses the node role |

## Apply

```bash
cd terraform/eks
terraform init -backend-config=../backend.hcl      # state: s3://ems-tfstate-<account>/eks/terraform.tfstate
terraform plan -out tfplan                          # ~30 resources
terraform apply tfplan                              # ~15 minutes
$(terraform output -raw update_kubeconfig_command)  # aws eks update-kubeconfig --name ems --region us-east-1
kubectl get nodes -o wide                           # 2 nodes Ready after ~2-3 minutes
```

If nodes never appear: check the ASG activity (`aws autoscaling describe-scaling-activities`), then the
instance console output for `nodeadm` errors, then `aws eks list-access-entries --cluster-name ems`.

## Cluster add-ons and the playground overlay

```bash
# storage for postgres-0 (EKS >= 1.30 has no default StorageClass)
aws eks create-addon --cluster-name ems --addon-name aws-ebs-csi-driver
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
  encrypted: "true"
EOF

# metrics-server (HPA) and ingress-nginx (NLB) as in docs/kubernetes/eks.md, then the app:
cp k8s/base/secret.env.example k8s/base/secret.env        # strong values
scripts/k8s/k8s-playground.sh --tag <git-sha> --dry-run   # see the commands first
scripts/k8s/k8s-playground.sh --tag <git-sha>
```

`k8s-playground.sh` renders `k8s/overlays/playground` (2 app pods + `postgres-0` = the 3-pods-per-namespace
limit, every pod <= 256m CPU / 512Mi), substitutes the ECR image of the current account and waits for the
rollout. See `docs/kubernetes/eks.md`.

## Destroy

```bash
kubectl delete namespace ems monitoring ingress-nginx   # deletes the NLB and the EBS volume first;
                                                        # otherwise their ENIs block the VPC deletion
terraform -chdir=terraform/eks destroy                  # ~10 minutes
scripts/aws/inventory.sh --expect-empty                 # after the other stacks are gone too
```

## Checks (no AWS account needed)

```bash
terraform -chdir=terraform/eks init -backend=false && terraform -chdir=terraform/eks validate
terraform -chdir=terraform/eks test       # mock provider: role names, no NAT, credits, IMDSv2, node limits
python3 terraform/tf_static_check.py
```
