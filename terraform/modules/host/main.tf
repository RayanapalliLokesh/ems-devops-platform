# One EC2 host: Amazon Linux 2023, standard CPU credits (unlimited is forbidden in the playground), IMDSv2
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-x86_64"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_key_pair" "this" {
  count      = var.ssh_public_key == "" ? 0 : 1
  key_name   = "${var.name}-deploy"
  public_key = var.ssh_public_key
  tags       = var.tags
}

resource "aws_instance" "this" {
  ami                    = var.ami_id != "" ? var.ami_id : data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = var.instance_profile_name
  key_name               = var.ssh_public_key == "" ? null : aws_key_pair.this[0].key_name
  user_data              = var.user_data
  monitoring             = false

  associate_public_ip_address = var.public_ip

  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # containers on the host may call IMDS for the role's credentials
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(var.tags, { Name = "${var.name}-host" })

  lifecycle {
    ignore_changes = [ami] # a newer AMI must not replace the running host; roll it deliberately
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.name}-host-cpu-high"
  alarm_description   = "EC2 CPU above 85% for 15 minutes (T3 credits drain; see docs/runbooks/HostHighCPU.md)"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { InstanceId = aws_instance.this.id }
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "status_check" {
  alarm_name          = "${var.name}-host-status-check"
  alarm_description   = "EC2 system or instance status check failed"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { InstanceId = aws_instance.this.id }
  tags                = var.tags
}
