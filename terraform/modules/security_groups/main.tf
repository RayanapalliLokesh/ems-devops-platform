# alb:  80 from anywhere          host: 80 from the alb group only, 22 from the admin CIDRs (none in prod)
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "EMS load balancer: HTTP from the internet"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-alb-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_host" {
  security_group_id            = aws_security_group.alb.id
  description                  = "HTTP to the hosts only"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.host.id
}

resource "aws_security_group" "host" {
  name        = "${var.name}-host-sg"
  description = "EMS host: HTTP from the ALB only, SSH from admins"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-host-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "host_http_from_alb" {
  security_group_id            = aws_security_group.host.id
  description                  = "HTTP from the load balancer"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_ingress_rule" "host_ssh" {
  for_each          = toset(var.ssh_cidrs)
  security_group_id = aws_security_group.host.id
  description       = "SSH from admin"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "host_all" {
  security_group_id = aws_security_group.host.id
  description       = "Packages, image pulls, S3"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
