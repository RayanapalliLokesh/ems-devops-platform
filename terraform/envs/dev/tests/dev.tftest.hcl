# Phase 21 - the dev environment wired together, planned and "applied" against mock providers only.
# No AWS account, no credentials, no backend: terraform test keeps its state in memory.
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
  mock_data "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:us-east-1:123456789012:repository/ems-app"
      repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/ems-app"
    }
  }
  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/ems-dev-alb/0123456789abcdef"
      arn_suffix = "app/ems-dev-alb/0123456789abcdef"
      dns_name   = "ems-dev-alb-123456789.us-east-1.elb.amazonaws.com"
    }
  }
  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/ems-dev-tg/0123456789abcdef"
      arn_suffix = "targetgroup/ems-dev-tg/0123456789abcdef"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

mock_provider "aws" {
  alias = "untagged"
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/ems-dev-host-policy"
    }
  }
}

mock_provider "random" {}

mock_provider "local" {}

variables {
  region         = "us-east-1"
  instance_type  = "t3.medium"
  ssh_cidrs      = ["203.0.113.7/32"]
  ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyOnly ems-deploy"
}

run "dev_has_no_nat_and_a_public_host" {
  command = plan

  assert {
    condition     = length(module.network.nat_gateway_ids) == 0
    error_message = "dev runs in the playground: no NAT gateway."
  }
  assert {
    condition     = length(module.network.public_subnet_ids) == 2 && length(module.network.private_subnet_ids) == 2
    error_message = "dev has two public and two private subnets."
  }
  assert {
    condition     = length(local.azs) == 2 && local.azs[0] == "us-east-1a" && local.azs[1] == "us-east-1b"
    error_message = "dev uses the first two availability zones."
  }
}

run "dev_outputs_after_a_mock_apply" {
  command = apply

  assert {
    condition     = startswith(output.app_url, "http://")
    error_message = "app_url is the ALB address."
  }
  assert {
    condition     = output.ecr_repository_url == "123456789012.dkr.ecr.us-east-1.amazonaws.com/ems-app"
    error_message = "The Ansible inventory and outputs use the existing ECR repository."
  }
  assert {
    condition     = yamldecode(local_file.ansible_inventory.content).all.children.ems_hosts.vars.ems_aws_region == "us-east-1"
    error_message = "The generated Ansible inventory carries the region."
  }
}

run "dev_rejects_a_region_outside_the_playground" {
  command = plan

  variables {
    region = "eu-west-1"
  }

  expect_failures = [var.region]
}
