# Control plane, its security group, and the access entry that lets the self-managed nodes join
resource "aws_security_group" "cluster" {
  name        = "${local.name}-cluster-sg"
  description = "EKS control plane: API from the nodes"
  vpc_id      = module.network.vpc_id
  tags        = { Name = "${local.name}-cluster-sg" }
}

resource "aws_security_group" "node" {
  name        = "${local.name}-node-sg"
  description = "EKS self-managed nodes"
  vpc_id      = module.network.vpc_id
  # exactly one security group per node carries the cluster tag: the in-tree LB controller adds NodePort rules to it
  tags = { Name = "${local.name}-node-sg", (local.cluster_tag) = "owned" }
}

# node -> cluster: the Kubernetes API
resource "aws_vpc_security_group_ingress_rule" "cluster_api_from_nodes" {
  security_group_id            = aws_security_group.cluster.id
  description                  = "Kubernetes API from the nodes"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.node.id
}

# cluster -> node: kubelet, webhooks and metrics-server/extension API servers
resource "aws_vpc_security_group_egress_rule" "cluster_to_nodes" {
  security_group_id            = aws_security_group.cluster.id
  description                  = "Kubelet and pods on the nodes"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 65535
  referenced_security_group_id = aws_security_group.node.id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_cluster" {
  security_group_id            = aws_security_group.node.id
  description                  = "Kubelet, webhooks and extension API servers from the control plane"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 65535
  referenced_security_group_id = aws_security_group.cluster.id
}

# node <-> node: pod-to-pod traffic and CoreDNS (the VPC CNI gives pods VPC addresses on the node ENIs)
resource "aws_vpc_security_group_ingress_rule" "nodes_from_nodes" {
  security_group_id            = aws_security_group.node.id
  description                  = "All traffic between nodes"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.node.id
}

resource "aws_vpc_security_group_egress_rule" "nodes_all" {
  security_group_id = aws_security_group.node.id
  description       = "Image pulls (ECR), EKS API, package repositories"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = concat(module.network.public_subnet_ids, module.network.private_subnet_ids)
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = var.public_access_cidrs
  }

  kubernetes_network_config {
    service_ipv4_cidr = var.service_cidr
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true # whoever runs apply gets cluster-admin
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# Nodes join through an access entry (no aws-auth ConfigMap edits needed); EC2_LINUX maps the role to
# system:nodes automatically
resource "aws_eks_access_entry" "node" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.node.arn
  type          = "EC2_LINUX"
}
