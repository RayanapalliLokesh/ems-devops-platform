output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  value = aws_eks_cluster.this.version
}

output "update_kubeconfig_command" {
  description = "Run this, then scripts/k8s/k8s-playground.sh --tag <git-sha>"
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${var.region}"
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "node_security_group_id" {
  value = aws_security_group.node.id
}

output "node_autoscaling_group" {
  value = aws_autoscaling_group.nodes.name
}

output "vpc_id" {
  value = module.network.vpc_id
}
