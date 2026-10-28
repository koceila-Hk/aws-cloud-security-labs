# ==================== Config Terraform et provider ====================
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = { Projet = "tp12-hello-again" }
  }
}

# ==================== Parametres ====================
variable "mon_ip" {
  description = "Mon IP publique en /32, seule autorisee en SSH sur l'admin"
  type        = string
}

locals {
  vpc_cidr = "10.5.0.0/16"
  azs      = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

# ==================== AMI : derniere Amazon Linux 2023 ====================
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}


# ==================== VPC ====================
resource "aws_vpc" "vpc" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "tp12-vpc" }

}

# ==================== Sous-reseaux ====================
# Admin : 10.5.0.0/24
resource "aws_subnet" "admin" {
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = cidrsubnet(local.vpc_cidr, 8, 0)
  availability_zone = local.azs[0]
  tags              = { Name = "tp12-subnet-admin" }
}

# Publics (proxies + ALB) : 10.5.10/11/12.0/24, un par AZ
resource "aws_subnet" "public" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = cidrsubnet(local.vpc_cidr, 8, 10 + count.index)
  availability_zone = local.azs[count.index]
  tags              = { Name = "tp12-subnet-public-${count.index + 1}" }
}

# Prives (web) : 10.5.2/3/4.0/24, un par AZ
resource "aws_subnet" "prive" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = cidrsubnet(local.vpc_cidr, 8, 2 + count.index)
  availability_zone = local.azs[count.index]
  tags              = { Name = "tp12-subnet-prive-${count.index + 1}" }
}

# ==================== Internet Gateway + NAT ====================
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
  tags   = { Name = "tp12-igw" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "tp12-eip-nat" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.admin.id
  tags          = { Name = "tp12-nat" }
  depends_on    = [aws_internet_gateway.igw]
}

# ==================== Routage ====================
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "tp12-rt-public" }
}

resource "aws_route_table_association" "admin" {
  subnet_id      = aws_subnet.admin.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "prive" {
  vpc_id = aws_vpc.vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "tp12-rt-prive" }
}

resource "aws_route_table_association" "prive" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.prive[count.index].id
  route_table_id = aws_route_table.prive.id
}

# ==================== Security Groups ====================
# Admin : SSH depuis mon IP uniquement (fleche bleue)
resource "aws_security_group" "admin" {
  name        = "tp12-sg-admin"
  description = "Admin - SSH depuis mon IP"
  vpc_id      = aws_vpc.vpc.id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.mon_ip]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "tp12-sg-admin" }
}

# ALB : HTTP depuis Internet (fleche verte)
resource "aws_security_group" "alb" {
  name        = "tp12-sg-alb"
  description = "ALB - HTTP public"
  vpc_id      = aws_vpc.vpc.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "tp12-sg-alb" }
}

# Proxies : HTTP depuis l'ALB seulement, SSH depuis l'admin
resource "aws_security_group" "proxy" {
  name        = "tp12-sg-proxy"
  description = "Proxies - HTTP depuis ALB, SSH depuis admin"
  vpc_id      = aws_vpc.vpc.id
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.admin.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "tp12-sg-proxy" }
}

# Web : HTTP depuis les proxies seulement, SSH depuis l'admin
resource "aws_security_group" "web" {
  name        = "tp12-sg-web"
  description = "Web - HTTP depuis proxies, SSH depuis admin"
  vpc_id      = aws_vpc.vpc.id
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.proxy.id]
  }
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.admin.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "tp12-sg-web" }
}

# ==================== Admin Machine ====================
resource "aws_instance" "admin" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = "t3.micro"
  key_name                    = "vockey"
  subnet_id                   = aws_subnet.admin.id
  vpc_security_group_ids      = [aws_security_group.admin.id]
  associate_public_ip_address = true
  metadata_options {
    http_tokens = "required"
  }
  root_block_device {
    encrypted = true
  }
  tags = { Name = "tp12-admin" }
}

# ==================== 3 serveurs web Apache (1 par AZ) ====================
resource "aws_instance" "web" {
  count                       = length(local.azs)
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = "t3.micro"
  key_name                    = "vockey"
  subnet_id                   = aws_subnet.prive[count.index].id
  vpc_security_group_ids      = [aws_security_group.web.id]
  user_data_replace_on_change = true
  metadata_options {
    http_tokens = "required"
  }
  root_block_device {
    encrypted = true
  }
  user_data  = <<-EOF
    #!/bin/bash
    dnf install -y httpd
    cat > /var/www/html/index.html <<HTML
    <h1>Web server ${count.index + 1}</h1>
    <p>Zone : ${local.azs[count.index]} - IP privee : $(hostname -I)</p>
    HTML
    systemctl enable --now httpd
  EOF
  depends_on = [aws_route_table_association.prive, aws_nat_gateway.nat]
  tags       = { Name = "tp12-web-${count.index + 1}" }
}

# ==================== 3 reverse proxies Nginx (1 par AZ) ====================
resource "aws_instance" "proxy" {
  count                       = length(local.azs)
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = "t3.micro"
  key_name                    = "vockey"
  subnet_id                   = aws_subnet.public[count.index].id
  vpc_security_group_ids      = [aws_security_group.proxy.id]
  associate_public_ip_address = true
  user_data_replace_on_change = true
  metadata_options {
    http_tokens = "required"
  }
  root_block_device {
    encrypted = true
  }
  user_data  = <<-EOF
    #!/bin/bash
    dnf install -y nginx
    cat > /etc/nginx/nginx.conf <<'CONF'
    events {}
    http {
      upstream web {
        ${join("\n", [for ip in aws_instance.web[*].private_ip : "server ${ip}:80 max_fails=1 fail_timeout=10s;"])}
      }
      server {
        listen 80;
        location / {
          proxy_pass http://web;
          proxy_connect_timeout 2s;
          proxy_next_upstream error timeout http_502 http_503;
          add_header X-Proxy $hostname always;
          add_header X-Web $upstream_addr always;
        }
      }
    }
    CONF
    systemctl enable --now nginx
  EOF
  depends_on = [aws_route_table_association.public]
  tags       = { Name = "tp12-proxy-${count.index + 1}" }
}

# ==================== Application Load Balancer ====================
resource "aws_lb" "alb" {
  name                       = "tp12-alb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.public[*].id
  drop_invalid_header_fields = true
  tags                       = { Name = "tp12-alb" }
}

resource "aws_lb_target_group" "proxies" {
  name                 = "tp12-tg-proxies"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = aws_vpc.vpc.id
  deregistration_delay = 10
  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group_attachment" "proxies" {
  count            = length(local.azs)
  target_group_arn = aws_lb_target_group.proxies.arn
  target_id        = aws_instance.proxy[count.index].id
  port             = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.proxies.arn
  }
}

# ==================== Sorties ====================
output "alb_dns" { value = aws_lb.alb.dns_name }
output "ip_admin" { value = aws_instance.admin.public_ip }
output "ips_proxies" { value = aws_instance.proxy[*].private_ip }
output "ips_web" { value = aws_instance.web[*].private_ip }
output "tg_arn" { value = aws_lb_target_group.proxies.arn }
