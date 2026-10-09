variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Public subnets in at least two zones"
  type        = list(string)
  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "An ALB needs subnets in at least two availability zones."
  }
}

variable "security_group_id" {
  type = string
}

variable "target_instance_ids" {
  description = "Instances to register, keyed by a static name (keys must be known at plan time)"
  type        = map(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
