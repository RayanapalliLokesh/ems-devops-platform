variable "name" {
  description = "Prefix of every resource name"
  type        = string
}

variable "cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
  validation {
    condition     = can(cidrhost(var.cidr, 0))
    error_message = "cidr must be a valid CIDR block."
  }
}

variable "azs" {
  description = "Availability zones (two: the ALB needs subnets in two zones)"
  type        = list(string)
  validation {
    condition     = length(var.azs) >= 2
    error_message = "At least two availability zones are required."
  }
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "nat_gateways" {
  description = "0 (playground), or one per zone (prod)"
  type        = number
  default     = 0
  validation {
    condition     = var.nat_gateways >= 0 && var.nat_gateways <= 2
    error_message = "nat_gateways must be 0, 1 or 2."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
