# Phase 21 - the host module: standard CPU credits, IMDSv2, encrypted gp3, playground size limits
mock_provider "aws" {}

override_data {
  target = data.aws_ami.al2023
  values = {
    id = "ami-0123456789abcdef0"
  }
}

variables {
  name                  = "ems-test"
  subnet_id             = "subnet-0123456789abcdef0"
  security_group_id     = "sg-0123456789abcdef0"
  instance_profile_name = "ems-test-host-profile"
}

run "playground_safe_defaults" {
  command = plan

  assert {
    condition     = aws_instance.this.credit_specification[0].cpu_credits == "standard"
    error_message = "CPU credits must be standard (unlimited suspends the playground session)."
  }
  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 (http_tokens = required) is mandatory."
  }
  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted == true && aws_instance.this.root_block_device[0].volume_type == "gp3"
    error_message = "The root volume must be encrypted gp3."
  }
  assert {
    condition     = aws_instance.this.root_block_device[0].volume_size == 20
    error_message = "The default root volume is 20 GB."
  }
  assert {
    condition     = aws_instance.this.ami == "ami-0123456789abcdef0"
    error_message = "An empty ami_id must use the latest Amazon Linux 2023 AMI."
  }
  assert {
    condition     = length(aws_key_pair.this) == 0 && aws_instance.this.associate_public_ip_address == false
    error_message = "Without a public key and public_ip (prod) there must be no key pair and no public IP."
  }
}

run "dev_style_public_host_with_key" {
  command = plan

  variables {
    instance_type  = "t3.medium"
    public_ip      = true
    ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyOnly ems-deploy"
  }

  assert {
    condition     = length(aws_key_pair.this) == 1 && aws_instance.this.associate_public_ip_address == true
    error_message = "A dev host with a key gets a key pair and a public IP."
  }
  assert {
    condition     = aws_instance.this.instance_type == "t3.medium"
    error_message = "instance_type must be passed through."
  }
}

run "rejects_t3_large" {
  command = plan

  variables {
    instance_type = "t3.large"
  }

  expect_failures = [var.instance_type]
}

run "rejects_a_40_gb_volume" {
  command = plan

  variables {
    volume_size_gb = 40
  }

  expect_failures = [var.volume_size_gb]
}
