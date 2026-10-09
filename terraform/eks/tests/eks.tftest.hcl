# Phase 23 - the EKS configuration planned against a mock AWS provider: playground names and limits
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-0123456789abcdef0"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "playground_cluster" {
  command = plan

  assert {
    condition     = aws_iam_role.cluster.name == "eksClusterRole" && aws_iam_role.node.name == "AmazonEKSNodeRole"
    error_message = "The playground requires the role names eksClusterRole and AmazonEKSNodeRole."
  }
  assert {
    condition     = length(module.network.nat_gateway_ids) == 0
    error_message = "No NAT gateway in the playground."
  }
  assert {
    condition     = aws_eks_cluster.this.version == "1.31" && aws_eks_cluster.this.access_config[0].authentication_mode == "API_AND_CONFIG_MAP"
    error_message = "Cluster version 1.31 with API_AND_CONFIG_MAP authentication."
  }
  assert {
    condition     = aws_eks_access_entry.node.type == "EC2_LINUX"
    error_message = "The node role joins through an EC2_LINUX access entry."
  }
  assert {
    condition     = aws_launch_template.node.credit_specification[0].cpu_credits == "standard" && aws_launch_template.node.instance_type == "t3.medium"
    error_message = "Nodes are t3.medium with standard CPU credits."
  }
  assert {
    condition     = aws_launch_template.node.metadata_options[0].http_tokens == "required" && aws_launch_template.node.metadata_options[0].http_put_response_hop_limit == 2
    error_message = "Nodes require IMDSv2 with hop limit 2."
  }
  assert {
    condition     = aws_launch_template.node.block_device_mappings[0].ebs[0].encrypted == "true" && aws_launch_template.node.block_device_mappings[0].ebs[0].volume_size == 20
    error_message = "Node volumes are encrypted 20 GB gp3."
  }
  assert {
    condition     = aws_launch_template.node.image_id == "ami-0123456789abcdef0"
    error_message = "The node AMI comes from the EKS-optimised AL2023 SSM parameter."
  }
  assert {
    condition     = aws_autoscaling_group.nodes.min_size == 1 && aws_autoscaling_group.nodes.desired_capacity == 2 && aws_autoscaling_group.nodes.max_size == 3
    error_message = "Node group: min 1, desired 2, max 3."
  }
  assert {
    condition     = length([for t in aws_autoscaling_group.nodes.tag : t if t.key == "kubernetes.io/cluster/ems" && t.value == "owned"]) == 1
    error_message = "Nodes carry kubernetes.io/cluster/<name> = owned."
  }
  assert {
    condition     = toset(values(aws_iam_role_policy_attachment.node)[*].policy_arn) == toset(["arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy", "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy", "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly", "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"])
    error_message = "The node role gets AWS-managed policies only."
  }
}

run "rejects_more_than_three_nodes" {
  command = plan

  variables {
    node_max_size = 4
  }

  expect_failures = [var.node_max_size]
}

run "rejects_a_large_node" {
  command = plan

  variables {
    node_instance_type = "t3.large"
  }

  expect_failures = [var.node_instance_type]
}
