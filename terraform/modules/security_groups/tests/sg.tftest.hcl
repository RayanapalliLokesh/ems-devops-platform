# Phase 21 - the security groups module: HTTP only through the ALB, SSH only from admin CIDRs (none in prod)
mock_provider "aws" {}

variables {
  name   = "ems-test"
  vpc_id = "vpc-0123456789abcdef0"
}

run "no_ssh_rule_when_ssh_cidrs_is_empty" {
  command = plan

  variables {
    ssh_cidrs = []
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.host_ssh) == 0
    error_message = "An empty ssh_cidrs list must not open port 22."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.host_http_from_alb.from_port == 80 && aws_vpc_security_group_ingress_rule.host_http_from_alb.cidr_ipv4 == null
    error_message = "The host must accept HTTP from the ALB security group only, not from a CIDR."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_http.cidr_ipv4 == "0.0.0.0/0" && aws_vpc_security_group_ingress_rule.alb_http.to_port == 80
    error_message = "The ALB must accept HTTP from anywhere."
  }
}

run "one_ssh_rule_per_admin_cidr" {
  command = plan

  variables {
    ssh_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.host_ssh) == 1
    error_message = "One admin CIDR must give exactly one SSH rule."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.host_ssh["203.0.113.7/32"].from_port == 22
    error_message = "The admin rule must open port 22."
  }
}

run "rejects_ssh_from_anywhere" {
  command = plan

  variables {
    ssh_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.ssh_cidrs]
}
