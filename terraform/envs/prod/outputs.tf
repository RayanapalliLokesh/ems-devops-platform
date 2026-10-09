output "alb_dns_name" {
  value = module.load_balancer.dns_name
}

output "app_url" {
  value = "http://${module.load_balancer.dns_name}"
}

output "host_private_ip" {
  value = module.host.private_ip
}

output "host_instance_id" {
  value = module.host.instance_id
}

output "host_security_group_id" {
  value = module.security_groups.host_sg_id
}

output "backup_bucket" {
  value = module.backup_bucket.bucket_name
}

output "ecr_repository_url" {
  value = data.aws_ecr_repository.app.repository_url
}

output "vpc_id" {
  value = module.network.vpc_id
}
