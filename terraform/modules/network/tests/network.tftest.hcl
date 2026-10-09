# Phase 21 - the network module, planned against a mock AWS provider (no account, no credentials)
mock_provider "aws" {}

variables {
  name = "ems-test"
  azs  = ["us-east-1a", "us-east-1b"]
}

run "two_public_two_private_no_nat_by_default" {
  command = plan

  assert {
    condition     = length(aws_subnet.public) == 2 && length(aws_subnet.private) == 2
    error_message = "Expected 2 public and 2 private subnets."
  }
  assert {
    condition     = [for s in aws_subnet.public : s.cidr_block] == ["10.0.1.0/24", "10.0.2.0/24"]
    error_message = "Public subnets must be 10.0.1.0/24 and 10.0.2.0/24."
  }
  assert {
    condition     = [for s in aws_subnet.private : s.cidr_block] == ["10.0.11.0/24", "10.0.12.0/24"]
    error_message = "Private subnets must be 10.0.11.0/24 and 10.0.12.0/24."
  }
  assert {
    condition     = alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch]) && !anytrue([for s in aws_subnet.private : s.map_public_ip_on_launch])
    error_message = "Only public subnets may assign public IPs."
  }
  assert {
    condition     = length(aws_nat_gateway.this) == 0 && length(aws_eip.nat) == 0 && length(aws_route.private_nat) == 0
    error_message = "The default (playground) network must have no NAT gateway, Elastic IP or NAT route."
  }
  assert {
    condition     = aws_route.public_internet.destination_cidr_block == "0.0.0.0/0"
    error_message = "The public route table needs a default route to the internet gateway."
  }
}

run "one_nat_per_zone_for_prod" {
  command = plan

  variables {
    nat_gateways = 2
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 2 && length(aws_eip.nat) == 2
    error_message = "nat_gateways = 2 must create two NAT gateways with an Elastic IP each."
  }
  assert {
    condition     = length(aws_route.private_nat) == 2
    error_message = "Each private route table needs a default route to a NAT gateway."
  }
}

run "rejects_a_single_availability_zone" {
  command = plan

  variables {
    azs = ["us-east-1a"]
  }

  expect_failures = [var.azs]
}

run "rejects_more_than_two_nat_gateways" {
  command = plan

  variables {
    nat_gateways = 3
  }

  expect_failures = [var.nat_gateways]
}
