variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "ssh_cidrs" {
  description = "CIDRs allowed to SSH to the host; empty list = no SSH at all (prod)"
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for c in var.ssh_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "ssh_cidrs must be valid CIDRs and must not be 0.0.0.0/0."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
