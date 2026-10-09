variable "name" {
  type = string
}

variable "retention_days" {
  type    = number
  default = 30
}

variable "force_destroy" {
  description = "Allow destroy with objects inside (true in the playground, false in prod)"
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
