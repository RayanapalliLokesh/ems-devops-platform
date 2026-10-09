output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "host_sg_id" {
  value = aws_security_group.host.id
}
