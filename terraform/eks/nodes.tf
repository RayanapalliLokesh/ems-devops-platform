# Self-managed nodes: launch template (EKS-optimised Amazon Linux 2023, nodeadm) + an Auto Scaling group
data "aws_ssm_parameter" "node_ami" {
  name = "/aws/service/eks/optimized-ami/${var.kubernetes_version}/amazon-linux-2023/x86_64/standard/recommended/image_id"
}

locals {
  # AL2023 nodes are configured by nodeadm from a NodeConfig document in a MIME multipart user data
  node_user_data = <<-EOT
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="BOUNDARY"

    --BOUNDARY
    Content-Type: application/node.eks.aws

    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      cluster:
        name: ${aws_eks_cluster.this.name}
        apiServerEndpoint: ${aws_eks_cluster.this.endpoint}
        certificateAuthority: ${aws_eks_cluster.this.certificate_authority[0].data}
        cidr: ${var.service_cidr}

    --BOUNDARY--
  EOT
}

resource "aws_launch_template" "node" {
  name_prefix   = "${local.name}-node-"
  description   = "EKS ${var.kubernetes_version} self-managed node for ${var.cluster_name}"
  image_id      = nonsensitive(data.aws_ssm_parameter.node_ami.value)
  instance_type = var.node_instance_type
  user_data     = base64encode(local.node_user_data)

  credit_specification {
    cpu_credits = "standard" # unlimited suspends the playground session
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.node.name
  }

  # public subnets and no NAT: nodes need a public IP to reach ECR and the EKS API
  network_interfaces {
    associate_public_ip_address = true
    delete_on_termination       = true
    security_groups             = [aws_security_group.node.id]
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # pods (VPC CNI, EBS CSI) reach IMDS through one extra hop
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = var.node_volume_size_gb
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name}-node", (local.cluster_tag) = "owned", Project = "ems" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${local.name}-node", Project = "ems" }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "nodes" {
  name                = "${local.name}-nodes"
  min_size            = var.node_min_size
  desired_capacity    = var.node_desired_size
  max_size            = var.node_max_size
  vpc_zone_identifier = module.network.public_subnet_ids
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-node"
    propagate_at_launch = true
  }

  tag {
    key                 = local.cluster_tag
    value               = "owned"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "ems"
    propagate_at_launch = true
  }

  lifecycle {
    precondition {
      condition     = var.node_min_size <= var.node_desired_size && var.node_desired_size <= var.node_max_size
      error_message = "Node group sizes must satisfy min <= desired <= max."
    }
  }

  # the role must be allowed to join before the first node boots
  depends_on = [aws_eks_access_entry.node, aws_iam_role_policy_attachment.node]
}
