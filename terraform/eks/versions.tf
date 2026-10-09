# Phase 23 - EKS in the KodeKloud playground. NOT applied by default: ~15 minutes to create, and the control
# plane costs money by the hour. State: s3://<bucket>/eks/terraform.tfstate (terraform init -backend-config=../backend.hcl)
terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
  backend "s3" {
    key = "eks/terraform.tfstate"
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "ems", ManagedBy = "terraform", Stack = "eks" }
  }
}
