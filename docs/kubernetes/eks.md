# EKS in the playground (Phase 23)

```
kind: localhost:8082 -> ingress-nginx -> Service -> pods (2-4, autoscaled)
EKS:  NLB :80 -> NodePort -> ingress-nginx -> Service -> pods (1-2) on self-managed nodes (ASG)
```

## How the pieces fit

| Layer | Where | What |
|---|---|---|
| Network | `terraform/modules/network` (phase 21), reused by `terraform/eks` | the same VPC module as the EC2 environments: public subnets in two AZs (tagged for load balancers), no NAT in the playground |
| Cluster | `terraform/eks` (maintained separately; not part of these manifests) | the EKS control plane plus **self-managed worker nodes**: an Auto Scaling group of t3 instances (t2/t3 nano-medium only, max 3 nodes per node group) using the EKS-optimised AMI, joined to the cluster through the node IAM role and the aws-auth/access entries |
| Image | ECR `ems-app` | the same image as everywhere else, pushed by the CD pipeline (phase 19) with an immutable tag |
| Workload | `k8s/overlays/playground` | the base plus playground limits (below) |
| Entry | ingress-nginx with a Service of type LoadBalancer (NLB) | NLB :80 -> node NodePort -> ingress-nginx -> Ingress `ems` -> Service `ems-app` |

## Playground limits and how the overlay respects them

| Limit | Overlay |
|---|---|
| max 3 pods per namespace | `ems-app` 2 replicas + `postgres-0` = 3. HPA `maxReplicas: 2`. Rolling update `maxSurge: 0`, `maxUnavailable: 1`: an old pod is removed before its replacement is created, so a rollout never needs a 4th pod (a surge pod would be rejected by the quota and the rollout would hang) |
| per pod max 256m CPU / 512Mi | app limits 250m/384Mi, postgres 250m/256Mi, init container 100m/64Mi (`tests/test_k8s.py` enforces this) |
| max 3 nodes per node group, t2/t3 nano-medium | set in `terraform/eks`; 3 small pods fit on one t3.small/medium |

Prometheus and Grafana (`k8s/monitoring`) run in their own namespace `monitoring`, so they do not count
against the 3 pods of `ems`. ingress-nginx runs in `ingress-nginx`.

## Deploy

```bash
aws eks update-kubeconfig --name ems --region us-east-1
cp k8s/base/secret.env.example k8s/base/secret.env    # set strong values (hex for the DB password)
scripts/k8s/k8s-playground.sh --tag <git-sha>          # --dry-run first to see the commands
scripts/k8s/k8s-rollout.sh --tag <new-sha>             # later rollouts, with automatic undo
```

`k8s-playground.sh` renders the overlay with `kubectl kustomize`, replaces the placeholders
`ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/ems-app:IMAGE_TAG` in the output (the account comes from
`aws sts get-caller-identity` unless `--account` is given), applies it and waits for the rollout. The overlay
in git stays account-free. Alternative: `cd k8s/overlays/playground && kustomize edit set image
ems-app=<account>.dkr.ecr.us-east-1.amazonaws.com/ems-app:<tag>` (do not commit the result).

## Things that differ from kind

- **Storage:** `data-postgres-0` needs a default StorageClass backed by the EBS CSI driver (add-on + IRSA or
  node-role permissions). Without it the PVC stays `Pending` and so does `postgres-0`. EBS volumes are bound
  to one AZ, so `postgres-0` can only be scheduled in that AZ afterwards.
- **NetworkPolicy:** enforced only if the VPC CNI network-policy agent (or Calico) is enabled; otherwise the
  policy is accepted but ignored.
- **Metrics:** install metrics-server for the HPA to work.
- **Image pulls:** the node IAM role needs `AmazonEC2ContainerRegistryReadOnly`; otherwise `ImagePullBackOff`.
- **Ingress:** ingress-nginx is installed with its AWS (NLB) manifest; the Ingress object is the same as on
  kind. `TRUSTED_PROXIES=1` (ingress-nginx is the one proxy that sets `X-Forwarded-For`; keep the NLB in TCP mode).
- **Clean up:** `kubectl delete namespace ems monitoring ingress-nginx` before `terraform destroy`, so the NLB
  created by the ingress controller's Service is deleted and does not block the VPC deletion.
