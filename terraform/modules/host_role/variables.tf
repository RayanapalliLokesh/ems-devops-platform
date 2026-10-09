variable "name" {
  type = string
}

variable "backup_bucket_arn" {
  type = string
}

variable "ecr_repository_arns" {
  description = "ECR repositories the host may pull from"
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
