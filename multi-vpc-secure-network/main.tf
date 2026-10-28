# =============================================================================
#  TP NOTÉ — Architecture multi-machines / multi-VPC (Terraform, us-east-1)
#  Auteur : Koceila HABAREK — M1 Cybersécurité
#
#  4 VPC, 6 subnets, 2 IGW, 1 NAT, 2 peerings, 1 NACL, 6 SG, 7 instances
#  EC1 : Squid :3128 (proxy sortant pour EC2/EC3) + HAProxy :80 (publie EC3)
#  EC4 : bastion SSH vers EC5 (VPC2) et EC6/EC7 (VPC4 via pcx-24)
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  # Tag commun posé automatiquement sur toutes les ressources (inventaire, coûts)
  default_tags {
    tags = { Projet = "tp-note" }
  }
}

# Ton IP publique en /32 : seule source autorisée en SSH (SG + NACL)
# Valeur dans terraform.tfvars (jamais versionné)
variable "mon_ip" {
  type        = string
  description = "Mon IP publique au format x.x.x.x/32"
}

locals {
  az = "us-east-1a"

  # IP privées FIXES => règles SG / NACL / Squid précises en /32
  ip = {
    ec1 = "10.1.1.10" # VPC1 subnet1 public : Squid + HAProxy
    ec2 = "10.1.2.10" # VPC1 subnet2 privé  : Ubuntu, apt via Squid
    ec3 = "10.3.1.10" # VPC3 subnet5 privé  : Apache (site privé)
    ec4 = "10.2.1.10" # VPC2 subnet3 public : bastion SSH
    ec5 = "10.2.2.10" # VPC2 subnet4 privé  : sort par la NAT (HTTPS seul)
    ec6 = "10.4.1.10" # VPC4 subnet6 privé  : Amazon Linux
    ec7 = "10.4.1.11" # VPC4 subnet6 privé  : Ubuntu
  }
}

# AMI toujours à jour via les paramètres publics SSM (pas d'ID en dur)
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# =============================================================================
# 1. RÉSEAU : 4 VPC, 6 subnets, 2 Internet Gateways
# =============================================================================
resource "aws_vpc" "vpc1" {
  cidr_block = "10.1.0.0/16"
  tags       = { Name = "tpn-vpc1" }
}

resource "aws_vpc" "vpc2" {
  cidr_block = "10.2.0.0/16"
  tags       = { Name = "tpn-vpc2" }
}

resource "aws_vpc" "vpc3" {
  cidr_block = "10.3.0.0/16"
  tags       = { Name = "tpn-vpc3" }
}

resource "aws_vpc" "vpc4" {
  cidr_block = "10.4.0.0/16"
  tags       = { Name = "tpn-vpc4" }
}

# Aucun subnet n'attribue d'IP publique automatiquement :
# l'IP publique est demandée explicitement sur EC1 et EC4 seulement.
resource "aws_subnet" "s1" {
  vpc_id            = aws_vpc.vpc1.id
  cidr_block        = "10.1.1.0/24"
  availability_zone = local.az
  tags              = { Name = "tpn-subnet1-public" }
}

resource "aws_subnet" "s2" {
  vpc_id            = aws_vpc.vpc1.id
  cidr_block        = "10.1.2.0/24"
  availability_zone = local.az
  tags              = { Name = "tpn-subnet2-prive" }
}

resource "aws_subnet" "s3" {
  vpc_id            = aws_vpc.vpc2.id
  cidr_block        = "10.2.1.0/24"
  availability_zone = local.az
  tags              = { Name = "tpn-subnet3-public" }
}

resource "aws_subnet" "s4" {
  vpc_id            = aws_vpc.vpc2.id
  cidr_block        = "10.2.2.0/24"
  availability_zone = local.az
  tags              = { Name = "tpn-subnet4-prive" }
}

resource "aws_subnet" "s5" {
  vpc_id            = aws_vpc.vpc3.id
  cidr_block        = "10.3.1.0/24"
  availability_zone = local.az
  tags              = { Name = "tpn-subnet5-prive" }
}

resource "aws_subnet" "s6" {
  vpc_id            = aws_vpc.vpc4.id
  cidr_block        = "10.4.1.0/24"
  availability_zone = local.az
  tags              = { Name = "tpn-subnet6-prive" }
}

# Internet Gateway uniquement pour VPC1 et VPC2 (VPC3/VPC4 : aucune passerelle)
resource "aws_internet_gateway" "igw1" {
  vpc_id = aws_vpc.vpc1.id
  tags   = { Name = "tpn-igw1" }
}

resource "aws_internet_gateway" "igw2" {
  vpc_id = aws_vpc.vpc2.id
  tags   = { Name = "tpn-igw2" }
}

# =============================================================================
# 2. NAT : Elastic IP + NAT Gateway dans le subnet 3 (public)
# =============================================================================
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "tpn-eip-nat" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.s3.id # subnet PUBLIC : la NAT sort elle-même par l'IGW
  tags          = { Name = "tpn-nat" }
  depends_on    = [aws_internet_gateway.igw2]
}

# =============================================================================
# 3. APPAIRAGES : pcx-13 (VPC1 <-> VPC3) et pcx-24 (VPC2 <-> VPC4)
#    Même compte + même région => auto_accept possible
# =============================================================================
resource "aws_vpc_peering_connection" "pcx13" {
  vpc_id      = aws_vpc.vpc1.id
  peer_vpc_id = aws_vpc.vpc3.id
  auto_accept = true
  tags        = { Name = "tpn-pcx-13" }
}

resource "aws_vpc_peering_connection" "pcx24" {
  vpc_id      = aws_vpc.vpc2.id
  peer_vpc_id = aws_vpc.vpc4.id
  auto_accept = true
  tags        = { Name = "tpn-pcx-24" }
}

# =============================================================================
# TABLES DE ROUTAGE
# Une table appartient à UN seul VPC : "la table publique des subnets 1 et 3"
# = une table publique dans VPC1 + une table publique dans VPC2.
# Chaque subnet a une table EXPLICITE (on ne dépend pas de la table "main").
# =============================================================================
resource "aws_route_table" "pub1" {
  vpc_id = aws_vpc.vpc1.id
  route {
    cidr_block = "0.0.0.0/0" # Internet
    gateway_id = aws_internet_gateway.igw1.id
  }
  route {
    cidr_block                = aws_vpc.vpc3.cidr_block # aller vers EC3 (HAProxy)
    vpc_peering_connection_id = aws_vpc_peering_connection.pcx13.id
  }
  tags = { Name = "tpn-rt-public-vpc1" }
}

# Subnet 2 : route "local" seule => EC2 ne sort que via Squid (même VPC)
resource "aws_route_table" "priv1" {
  vpc_id = aws_vpc.vpc1.id
  tags   = { Name = "tpn-rt-prive-vpc1" }
}

resource "aws_route_table" "pub2" {
  vpc_id = aws_vpc.vpc2.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw2.id
  }
  route {
    cidr_block                = aws_vpc.vpc4.cidr_block # bastion -> EC6/EC7
    vpc_peering_connection_id = aws_vpc_peering_connection.pcx24.id
  }
  tags = { Name = "tpn-rt-public-vpc2" }
}

resource "aws_route_table" "priv2" {
  vpc_id = aws_vpc.vpc2.id
  route {
    cidr_block     = "0.0.0.0/0" # subnet4 -> NAT -> IGW2
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "tpn-rt-prive-vpc2" }
}

# Routes retour : sans elles, les réponses sont perdues
resource "aws_route_table" "vpc3" {
  vpc_id = aws_vpc.vpc3.id
  route {
    cidr_block                = aws_vpc.vpc1.cidr_block # EC3 -> Squid + réponses HTTP
    vpc_peering_connection_id = aws_vpc_peering_connection.pcx13.id
  }
  tags = { Name = "tpn-rt-vpc3" }
}

resource "aws_route_table" "vpc4" {
  vpc_id = aws_vpc.vpc4.id
  route {
    cidr_block                = aws_vpc.vpc2.cidr_block # réponses SSH vers le bastion
    vpc_peering_connection_id = aws_vpc_peering_connection.pcx24.id
  }
  tags = { Name = "tpn-rt-vpc4" }
}

resource "aws_route_table_association" "s1" {
  subnet_id      = aws_subnet.s1.id
  route_table_id = aws_route_table.pub1.id
}

resource "aws_route_table_association" "s2" {
  subnet_id      = aws_subnet.s2.id
  route_table_id = aws_route_table.priv1.id
}

resource "aws_route_table_association" "s3" {
  subnet_id      = aws_subnet.s3.id
  route_table_id = aws_route_table.pub2.id
}

resource "aws_route_table_association" "s4" {
  subnet_id      = aws_subnet.s4.id
  route_table_id = aws_route_table.priv2.id
}

resource "aws_route_table_association" "s5" {
  subnet_id      = aws_subnet.s5.id
  route_table_id = aws_route_table.vpc3.id
}

resource "aws_route_table_association" "s6" {
  subnet_id      = aws_subnet.s6.id
  route_table_id = aws_route_table.vpc4.id
}

# =============================================================================
# 4. NACL DU SUBNET 1 — stateless : il faut autoriser les deux sens,
#    y compris les ports éphémères de retour (1024-65535). Tout le reste : DENY.
# =============================================================================
resource "aws_network_acl" "nacl1" {
  vpc_id     = aws_vpc.vpc1.id
  subnet_ids = [aws_subnet.s1.id] # remplace l'association avec la NACL par défaut

  # ---------- ENTRÉE
  ingress { # SSH admin depuis mon IP uniquement
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.mon_ip
    from_port  = 22
    to_port    = 22
  }
  ingress { # HTTP public -> HAProxy
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }
  ingress { # Squid <- EC2 (subnet 2)
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = aws_subnet.s2.cidr_block
    from_port  = 3128
    to_port    = 3128
  }
  ingress { # Squid <- EC3 (subnet 5, via pcx-13)
    rule_no    = 130
    protocol   = "tcp"
    action     = "allow"
    cidr_block = aws_subnet.s5.cidr_block
    from_port  = 3128
    to_port    = 3128
  }
  ingress { # retours des connexions sortantes (dnf, Squid, HAProxy, rebond SSH)
    rule_no    = 140
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # ---------- SORTIE
  egress { # HTTPS sortant (Squid, dnf)
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }
  egress { # HTTP : HAProxy -> EC3, Squid -> miroirs apt Ubuntu
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }
  egress { # rebond SSH EC1 -> EC2
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = aws_subnet.s2.cidr_block
    from_port  = 22
    to_port    = 22
  }
  egress { # rebond SSH EC1 -> EC3
    rule_no    = 130
    protocol   = "tcp"
    action     = "allow"
    cidr_block = aws_subnet.s5.cidr_block
    from_port  = 22
    to_port    = 22
  }
  egress { # réponses aux clients (SSH, HTTP, Squid)
    rule_no    = 140
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  tags = { Name = "tpn-nacl-1" }
}

# =============================================================================
# 5. GROUPES DE SÉCURITÉ — stateful, strict nécessaire
#    Terraform supprime la sortie "tout autorisé" par défaut : seules les
#    règles egress écrites ici existent.
# =============================================================================
resource "aws_security_group" "ec1" {
  name        = "tpn-sg-ec1"
  description = "EC1 Squid + HAProxy"
  vpc_id      = aws_vpc.vpc1.id

  ingress {
    description = "SSH admin"
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = [var.mon_ip]
  }
  ingress {
    description = "Site public HAProxy"
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "Squid pour EC2 et EC3 uniquement"
    protocol    = "tcp"
    from_port   = 3128
    to_port     = 3128
    cidr_blocks = ["${local.ip.ec2}/32", "${local.ip.ec3}/32"]
  }
  egress {
    description = "HTTPS Squid et dnf"
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "HTTP Squid apt et backend EC3"
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "Rebond SSH vers EC2 et EC3"
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = ["${local.ip.ec2}/32", "${local.ip.ec3}/32"]
  }
  tags = { Name = "tpn-sg-ec1" }
}

resource "aws_security_group" "ec2" {
  name        = "tpn-sg-ec2"
  description = "EC2 sortie uniquement via Squid"
  vpc_id      = aws_vpc.vpc1.id

  ingress {
    description = "SSH depuis EC1"
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = ["${local.ip.ec1}/32"]
  }
  egress {
    description = "Sortie uniquement par Squid"
    protocol    = "tcp"
    from_port   = 3128
    to_port     = 3128
    cidr_blocks = ["${local.ip.ec1}/32"]
  }
  tags = { Name = "tpn-sg-ec2" }
}

resource "aws_security_group" "ec3" {
  name        = "tpn-sg-ec3"
  description = "EC3 Apache prive"
  vpc_id      = aws_vpc.vpc3.id

  ingress {
    description = "HTTP depuis HAProxy EC1"
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["${local.ip.ec1}/32"]
  }
  ingress {
    description = "SSH depuis EC1"
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = ["${local.ip.ec1}/32"]
  }
  egress {
    description = "Sortie uniquement par Squid"
    protocol    = "tcp"
    from_port   = 3128
    to_port     = 3128
    cidr_blocks = ["${local.ip.ec1}/32"]
  }
  tags = { Name = "tpn-sg-ec3" }
}

resource "aws_security_group" "ec4" {
  name        = "tpn-sg-ec4"
  description = "EC4 bastion SSH"
  vpc_id      = aws_vpc.vpc2.id

  ingress {
    description = "SSH admin"
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = [var.mon_ip]
  }
  egress {
    description = "Rebond SSH vers EC5 EC6 EC7"
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = ["${local.ip.ec5}/32", aws_subnet.s6.cidr_block]
  }
  tags = { Name = "tpn-sg-ec4" }
}

resource "aws_security_group" "ec5" {
  name        = "tpn-sg-ec5"
  description = "EC5 SSH entrant seul et HTTPS sortant seul"
  vpc_id      = aws_vpc.vpc2.id

  ingress {
    description = "SSH depuis le bastion"
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = ["${local.ip.ec4}/32"]
  }
  egress {
    description = "HTTPS sortant uniquement"
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "tpn-sg-ec5" }
}

resource "aws_security_group" "ec67" {
  name        = "tpn-sg-ec6-ec7"
  description = "EC6 EC7 SSH depuis bastion, aucune sortie"
  vpc_id      = aws_vpc.vpc4.id

  ingress {
    description = "SSH depuis le bastion via pcx-24"
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = ["${local.ip.ec4}/32"]
  }
  # aucune règle egress : les réponses SSH passent quand même (stateful)
  tags = { Name = "tpn-sg-ec6-ec7" }
}

# =============================================================================
# 6-7. USER_DATA (scripts exécutés au 1er démarrage)
# =============================================================================
locals {
  # EC1 : Squid (proxy sortant réservé à EC2/EC3) + HAProxy (publie EC3 sur :80)
  ud_ec1 = <<-EOF
    #!/bin/bash
    dnf install -y squid haproxy

    cat > /etc/squid/squid.conf <<'CONF'
    http_port 3128
    # Seuls EC2 et EC3 ont le droit d'utiliser le proxy
    acl clients_autorises src ${local.ip.ec2}/32
    acl clients_autorises src ${local.ip.ec3}/32
    acl SSL_ports port 443
    acl Safe_ports port 80
    acl Safe_ports port 443
    acl CONNECT method CONNECT
    http_access deny !Safe_ports
    http_access deny CONNECT !SSL_ports
    http_access allow clients_autorises
    http_access deny all
    cache deny all
    access_log /var/log/squid/access.log squid
    coredump_dir /var/spool/squid
    CONF

    cat > /etc/haproxy/haproxy.cfg <<'CONF'
    global
        log /dev/log local0
        user haproxy
        group haproxy
        daemon

    defaults
        mode http
        log global
        option httplog
        timeout connect 5s
        timeout client  30s
        timeout server  30s

    frontend site_public
        bind *:80
        http-response set-header X-Reverse-Proxy haproxy-ec1
        default_backend apache_ec3

    backend apache_ec3
        server ec3 ${local.ip.ec3}:80 check inter 5s
    CONF

    systemctl enable --now squid haproxy
  EOF

  # EC3 : VPC3 n'a aucune passerelle => dnf passe par Squid (via pcx-13)
  ud_ec3 = <<-EOF
    #!/bin/bash
    echo "proxy=http://${local.ip.ec1}:3128" >> /etc/dnf/dnf.conf
    # Attendre que Squid (EC1) soit prêt avant d'installer Apache
    until curl -s -o /dev/null -m 5 -x http://${local.ip.ec1}:3128 https://aws.amazon.com; do sleep 10; done
    dnf install -y httpd
    echo "<h1>Site prive EC3</h1><p>VPC3 ${local.ip.ec3} - publie par HAProxy (EC1) via pcx-13</p>" > /var/www/html/index.html
    systemctl enable --now httpd
  EOF

  # EC2 : apt passe par Squid
  ud_ec2 = <<-EOF
    #!/bin/bash
    cat > /etc/apt/apt.conf.d/95proxy <<'CONF'
    Acquire::http::Proxy "http://${local.ip.ec1}:3128";
    Acquire::https::Proxy "http://${local.ip.ec1}:3128";
    CONF
    until curl -s -o /dev/null -m 5 -x http://${local.ip.ec1}:3128 https://aws.amazon.com; do sleep 10; done
    apt-get update
  EOF

  # Description des 7 instances => une seule ressource aws_instance (for_each)
  instances = {
    ec1 = { ami = data.aws_ssm_parameter.al2023.value, subnet = aws_subnet.s1.id, sg = aws_security_group.ec1.id, public = true, user_data = local.ud_ec1 }
    ec2 = { ami = data.aws_ssm_parameter.ubuntu.value, subnet = aws_subnet.s2.id, sg = aws_security_group.ec2.id, public = false, user_data = local.ud_ec2 }
    ec3 = { ami = data.aws_ssm_parameter.al2023.value, subnet = aws_subnet.s5.id, sg = aws_security_group.ec3.id, public = false, user_data = local.ud_ec3 }
    ec4 = { ami = data.aws_ssm_parameter.al2023.value, subnet = aws_subnet.s3.id, sg = aws_security_group.ec4.id, public = true, user_data = null }
    ec5 = { ami = data.aws_ssm_parameter.al2023.value, subnet = aws_subnet.s4.id, sg = aws_security_group.ec5.id, public = false, user_data = null }
    ec6 = { ami = data.aws_ssm_parameter.al2023.value, subnet = aws_subnet.s6.id, sg = aws_security_group.ec67.id, public = false, user_data = null }
    ec7 = { ami = data.aws_ssm_parameter.ubuntu.value, subnet = aws_subnet.s6.id, sg = aws_security_group.ec67.id, public = false, user_data = null }
  }
}

# =============================================================================
# INSTANCES
# =============================================================================
resource "aws_instance" "ec" {
  for_each = local.instances

  ami                         = each.value.ami
  instance_type               = "t3.micro"
  key_name                    = "vockey"
  subnet_id                   = each.value.subnet
  private_ip                  = local.ip[each.key]
  vpc_security_group_ids      = [each.value.sg]
  associate_public_ip_address = each.value.public
  user_data                   = each.value.user_data
  user_data_replace_on_change = true

  metadata_options {
    http_tokens   = "required" # IMDSv2 obligatoire (anti-SSRF)
    http_endpoint = "enabled"
  }

  root_block_device {
    encrypted = true # disque chiffré au repos
  }

  tags = { Name = "tpn-${each.key}" }

  # Le réseau (routes, NACL, NAT, peerings) doit être prêt avant le user_data
  depends_on = [
    aws_route_table_association.s1, aws_route_table_association.s2,
    aws_route_table_association.s3, aws_route_table_association.s4,
    aws_route_table_association.s5, aws_route_table_association.s6,
    aws_network_acl.nacl1,
  ]
}

# =============================================================================
# SORTIES (utilisées par tests.sh)
# =============================================================================
output "ec1_public_ip" {
  value = aws_instance.ec["ec1"].public_ip
}

output "ec4_public_ip" {
  value = aws_instance.ec["ec4"].public_ip
}

output "nat_public_ip" {
  value = aws_eip.nat.public_ip
}

output "ec3_id" {
  value = aws_instance.ec["ec3"].id
}

output "nacl1_id" {
  value = aws_network_acl.nacl1.id
}

output "ips_privees" {
  value = local.ip
}
