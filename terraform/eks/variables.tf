variable "region" {
  description = "Playground regions: us-east-1, us-west-2, us-east-2"
  type        = string
  default     = "us-east-1"
  validation {
    condition     = contains(["us-east-1", "us-west-2", "us-east-2"], var.region)
    error_message = "The playground supports us-east-1, us-west-2 and us-east-2 only."
  }
}

variable "cluster_name" {
  description = "EKS cluster name (docs/kubernetes/eks.md uses `aws eks update-kubeconfig --name ems`)"
  type        = string
  default     = "ems"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version; also selects the EKS-optimised AL2023 AMI from SSM"
  type        = string
  default     = "1.31"
  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version looks like 1.31."
  }
}

variable "vpc_cidr" {
  description = "A different range from envs/dev (10.0.0.0/16), so both can exist side by side"
  type        = string
  default     = "10.1.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes Service CIDR (passed to the cluster and to nodeadm)"
  type        = string
  default     = "172.20.0.0/16"
}

variable "node_instance_type" {
  description = "Playground: t2/t3 nano-medium only"
  type        = string
  default     = "t3.medium"
  validation {
    condition     = contains(["t2.nano", "t2.micro", "t2.small", "t2.medium", "t3.nano", "t3.micro", "t3.small", "t3.medium"], var.node_instance_type)
    error_message = "node_instance_type must be a t2/t3 nano, micro, small or medium (playground limit)."
  }
}

variable "node_volume_size_gb" {
  type    = number
  default = 20
  validation {
    condition     = var.node_volume_size_gb >= 20 && var.node_volume_size_gb <= 30
    error_message = "Node volumes must be 20-30 GB (EKS AMI needs 20, playground limit 30)."
  }
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  description = "Playground: at most 3 nodes per node group"
  type        = number
  default     = 3
  validation {
    condition     = var.node_max_size >= 1 && var.node_max_size <= 3
    error_message = "node_max_size must be 1-3 (playground limit: 3 nodes per node group)."
  }
}

variable "public_access_cidrs" {
  description = "Who may reach the public Kubernetes API endpoint (narrow it to your IP/32)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ebs_csi_node_policy" {
  description = "Attach AmazonEBSCSIDriverPolicy to the node role so the EBS CSI add-on can create the postgres volume"
  type        = bool
  default     = true
}
