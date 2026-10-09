# Phase 21 - prod: the same modules as dev with production values. PLANNED ONLY (never applied in the playground):
# private host (no public IP, no SSH: deploys through SSM or a bastion), one NAT gateway per zone
terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
  backend "s3" {
    key = "envs/prod/terraform.tfstate"
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "ems", Environment = var.environment, ManagedBy = "terraform" }
  }
}

# The playground forbids iam:TagPolicy: IAM policies are created without default tags
provider "aws" {
  alias  = "untagged"
  region = var.region
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ecr_repository" "app" {
  name = var.ecr_repository_name
}

locals {
  name = "ems-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "network" {
  source               = "../../modules/network"
  name                 = local.name
  cidr                 = var.vpc_cidr
  azs                  = local.azs
  public_subnet_cidrs  = [cidrsubnet(var.vpc_cidr, 8, 1), cidrsubnet(var.vpc_cidr, 8, 2)]
  private_subnet_cidrs = [cidrsubnet(var.vpc_cidr, 8, 11), cidrsubnet(var.vpc_cidr, 8, 12)]
  nat_gateways         = 2
}

module "security_groups" {
  source    = "../../modules/security_groups"
  name      = local.name
  vpc_id    = module.network.vpc_id
  ssh_cidrs = []
}

module "backup_bucket" {
  source        = "../../modules/backup_bucket"
  name          = local.name
  force_destroy = false
}

module "host_role" {
  source              = "../../modules/host_role"
  providers           = { aws = aws, aws.untagged = aws.untagged }
  name                = local.name
  backup_bucket_arn   = module.backup_bucket.bucket_arn
  ecr_repository_arns = [data.aws_ecr_repository.app.arn]
}

module "host" {
  source                = "../../modules/host"
  name                  = local.name
  instance_type         = var.instance_type
  subnet_id             = module.network.private_subnet_ids[0]
  security_group_id     = module.security_groups.host_sg_id
  instance_profile_name = module.host_role.instance_profile_name
  public_ip             = false
  ssh_public_key        = ""
  user_data             = file("${path.module}/../../../deploy/aws/user-data.sh")
  volume_size_gb        = 20
}

module "load_balancer" {
  source              = "../../modules/load_balancer"
  name                = local.name
  vpc_id              = module.network.vpc_id
  subnet_ids          = module.network.public_subnet_ids
  security_group_id   = module.security_groups.alb_sg_id
  target_instance_ids = { host = module.host.instance_id }
}

# The only thing Ansible reads from Terraform: where the host is and what it should use
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../../../ansible/inventories/aws/hosts-prod.yml"
  file_permission = "0644"
  content = yamlencode({
    all = {
      children = {
        ems_hosts = {
          hosts = {
            ems-host = {
              ansible_host = module.host.private_ip
              ansible_user = "ec2-user"
            }
          }
          vars = {
            ems_environment     = var.environment
            ems_image           = data.aws_ecr_repository.app.repository_url
            ems_ecr_registry    = split("/", data.aws_ecr_repository.app.repository_url)[0]
            ems_aws_region      = var.region
            ems_backup_bucket   = module.backup_bucket.bucket_name
            ems_alb_dns_name    = module.load_balancer.dns_name
            ems_trusted_proxies = 2
          }
        }
      }
    }
  })
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = local.name
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title = "ALB requests and target 5xx", region = var.region, stat = "Sum", period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", module.load_balancer.arn_suffix],
            [".", "HTTPCode_Target_5XX_Count", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title   = "Target response time (p95)", region = var.region, stat = "p95", period = 60
          metrics = [["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", module.load_balancer.arn_suffix]]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title = "Healthy / unhealthy targets", region = var.region, stat = "Maximum", period = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", module.load_balancer.target_group_arn_suffix, "LoadBalancer", module.load_balancer.arn_suffix],
            [".", "UnHealthyHostCount", ".", ".", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title = "Host CPU and credit balance", region = var.region, stat = "Average", period = 300
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", module.host.instance_id],
            [".", "CPUCreditBalance", ".", "."],
          ]
        }
      },
    ]
  })
}
