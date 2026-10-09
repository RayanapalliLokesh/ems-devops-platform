variable "name" {
  type = string
}

variable "instance_type" {
  description = "Playground: t2/t3 nano-medium only (max 2 vCPU, 4 GB)"
  type        = string
  default     = "t3.small"
  validation {
    condition     = contains(["t2.nano", "t2.micro", "t2.small", "t2.medium", "t3.nano", "t3.micro", "t3.small", "t3.medium"], var.instance_type)
    error_message = "instance_type must be a t2/t3 nano, micro, small or medium (playground limit)."
  }
}

variable "ami_id" {
  description = "Empty = latest Amazon Linux 2023"
  type        = string
  default     = ""
}

variable "subnet_id" {
  type = string
}

variable "security_group_id" {
  type = string
}

variable "instance_profile_name" {
  type = string
}

variable "public_ip" {
  description = "true in dev (SSH from the admin IP), false in prod (private subnet)"
  type        = bool
  default     = false
}

variable "ssh_public_key" {
  description = "Public key for the deploy user; empty = no key pair (prod)"
  type        = string
  default     = ""
}

variable "user_data" {
  type    = string
  default = null
}

variable "volume_size_gb" {
  type    = number
  default = 20
  validation {
    condition     = var.volume_size_gb >= 8 && var.volume_size_gb <= 30
    error_message = "Root volume must be 8-30 GB (playground limit 30)."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
