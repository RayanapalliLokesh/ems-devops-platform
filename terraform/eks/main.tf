# Network (the phase 21 module) and the two IAM roles. The playground expects these exact role names, and
# it denies inline role policies, so only AWS-managed policies are attached.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = "${var.cluster_name}-eks"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)
  # tag that lets EKS and the in-tree load balancer controller recognise the cluster's resources
  cluster_tag = "kubernetes.io/cluster/${var.cluster_name}"
}

# No NAT in the playground: nodes run in the public subnets with public IPs (security groups keep them closed)
module "network" {
  source               = "../modules/network"
  name                 = local.name
  cidr                 = var.vpc_cidr
  azs                  = local.azs
  public_subnet_cidrs  = [cidrsubnet(var.vpc_cidr, 8, 1), cidrsubnet(var.vpc_cidr, 8, 2)]
  private_subnet_cidrs = [cidrsubnet(var.vpc_cidr, 8, 11), cidrsubnet(var.vpc_cidr, 8, 12)]
  nat_gateways         = 0
  tags                 = { (local.cluster_tag) = "shared" }
}

# ---- cluster role ------------------------------------------------------------------------------------
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "eksClusterRole" # exact name required by the playground
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---- node role ---------------------------------------------------------------------------------------
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "AmazonEKSNodeRole" # exact name required by the playground
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

locals {
  node_policies = merge(
    {
      worker = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
      cni    = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
      ecr    = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    },
    var.ebs_csi_node_policy ? { ebs_csi = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy" } : {},
  )
}

# static keys (known at plan time) so for_each works before anything exists
resource "aws_iam_role_policy_attachment" "node" {
  for_each   = local.node_policies
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "node" {
  name = "${local.name}-node-profile"
  role = aws_iam_role.node.name
}
