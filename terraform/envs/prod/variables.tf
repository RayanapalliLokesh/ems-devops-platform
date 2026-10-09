variable "region" {
  description = "Playground regions: us-east-1, us-west-2, us-east-2"
  type        = string
  default     = "us-east-1"
  validation {
    condition     = contains(["us-east-1", "us-west-2", "us-east-2"], var.region)
    error_message = "The playground supports us-east-1, us-west-2 and us-east-2 only."
  }
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "instance_type" {
  description = "prod runs the same size as dev; it is planned, never applied in the playground"
  type        = string
  default     = "t3.medium"
}

variable "ecr_repository_name" {
  type    = string
  default = "ems-app"
}
