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
  default = "dev"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "instance_type" {
  description = "t3.medium: the app stack plus the monitoring stack need about 2.5 GB"
  type        = string
  default     = "t3.medium"
}

variable "ssh_cidrs" {
  description = "Admin addresses allowed to SSH, e.g. [\"203.0.113.7/32\"] (curl -s https://checkip.amazonaws.com)"
  type        = list(string)
}

variable "ssh_public_key" {
  description = "Public key of the deploy key pair (the private key is the CD secret EMS_SSH_KEY)"
  type        = string
}

variable "ecr_repository_name" {
  type    = string
  default = "ems-app"
}
