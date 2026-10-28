#!/usr/bin/env bash
# =============================================================================
#  TP NOTÉ — Tests de l'architecture (1 capture par test)
#  Usage : ./tests.sh            (dans le dossier du main.tf, après apply)
#  Prérequis : eval $(ssh-agent) && ssh-add ~/.ssh/labsuser.pem
# =============================================================================
export AWS_DEFAULT_REGION=us-east-1 AWS_PAGER=""
cd "$(dirname "$0")"

EC1=$(terraform output -raw ec1_public_ip)
EC4=$(terraform output -raw ec4_public_ip)
NAT=$(terraform output -raw nat_public_ip)
EC3_ID=$(terraform output -raw ec3_id)
NACL=$(terraform output -raw nacl1_id)
SSHO="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=8"
J1="-J ec2-user@$EC1"
J4="-J ec2-user@$EC4"

t() { echo; echo "##### $* #####"; }

ssh-add -l >/dev/null 2>&1 || { echo "[!] eval \$(ssh-agent) && ssh-add ~/.ssh/labsuser.pem"; exit 1; }

# Les premières connexions directes enregistrent les clés des bastions
# (les options -o ne s'appliquent pas aux hôtes de rebond -J)
t "T0  Attente : Squid + HAProxy actifs sur EC1"
until ssh $SSHO ec2-user@"$EC1" 'systemctl is-active --quiet squid haproxy' 2>/dev/null; do sleep 10; done
echo "EC1 prêt"
ssh $SSHO ec2-user@"$EC4" true

t "T1  Site public : Internet -> IGW1 -> HAProxy EC1 -> pcx-13 -> Apache EC3"
curl -s -D - "http://$EC1/" | tr -d '\r'

t "T2  EC3 n'a pas d'IP publique (site privé)"
aws ec2 describe-instances --instance-ids "$EC3_ID" \
  --query 'Reservations[0].Instances[0].[PrivateIpAddress,PublicIpAddress]' --output text

t "T3  EC3 : Apache installé via Squid"
ssh $SSHO $J1 ec2-user@10.3.1.10 'grep ^proxy /etc/dnf/dnf.conf; rpm -q httpd; systemctl is-active httpd'

t "T4  EC2 : apt update via Squid"
ssh $SSHO $J1 ubuntu@10.1.2.10 'cat /etc/apt/apt.conf.d/95proxy; sudo apt-get update 2>&1 | tail -4'

t "T5  Journal Squid : clients et destinations"
ssh $SSHO ec2-user@"$EC1" 'sudo awk "{print \$3, \$6, \$7}" /var/log/squid/access.log | sort | uniq -c | sort -rn | head -15'

t "T6  EC2 : sortie directe BLOQUÉE / via Squid OK"
ssh $SSHO $J1 ubuntu@10.1.2.10 '
  curl -m5 -s -o /dev/null https://example.com && echo DIRECT=OK || echo DIRECT=BLOQUE
  curl -m5 -s -o /dev/null -w "VIA_SQUID=%{http_code}\n" -x http://10.1.1.10:3128 https://example.com'

t "T7  Squid refuse un client non autorisé (EC1 lui-même) -> 403"
ssh $SSHO ec2-user@"$EC1" 'curl -s -o /dev/null -w "HTTP %{http_code}\n" -x http://127.0.0.1:3128 http://example.com'

t "T8  Squid non exposé sur Internet (timeout attendu)"
curl -m5 -s -o /dev/null -x "http://$EC1:3128" http://example.com && echo EXPOSE || echo BLOQUE

t "T9  NACL du subnet 1"
aws ec2 describe-network-acls --network-acl-ids "$NACL" \
  --query 'NetworkAcls[0].Entries[?RuleNumber<`32767`].{Sortie:Egress,N:RuleNumber,De:PortRange.From,A:PortRange.To,CIDR:CidrBlock,Action:RuleAction}' \
  --output table

t "T10 Bastion EC4 -> EC5 (VPC2) -> EC6/EC7 (VPC4 via pcx-24)"
ssh $SSHO $J4 ec2-user@10.2.2.10 hostname
ssh $SSHO $J4 ec2-user@10.4.1.10 hostname
ssh $SSHO $J4 ubuntu@10.4.1.11   hostname

t "T11 EC5 sort par la NAT (IP vue = EIP de la NAT : $NAT)"
ssh $SSHO $J4 ec2-user@10.2.2.10 'curl -s https://checkip.amazonaws.com'

t "T12 EC5 : HTTPS OK / HTTP BLOQUÉ (SG sortie 443 seul)"
ssh $SSHO $J4 ec2-user@10.2.2.10 '
  curl -m5 -s -o /dev/null -w "HTTPS=%{http_code}\n" https://example.com
  curl -m5 -s -o /dev/null http://example.com && echo HTTP=OK || echo HTTP=BLOQUE'

t "T13 EC6 (VPC4) : aucun accès Internet"
ssh $SSHO $J4 ec2-user@10.4.1.10 'curl -m5 -s -o /dev/null https://example.com && echo INTERNET=OK || echo INTERNET=BLOQUE'

t "T14 Tables de routage (IGW / NAT / pcx dans les deux sens)"
aws ec2 describe-route-tables --filters Name=tag:Projet,Values=tp-note \
  --query 'RouteTables[].[Tags[?Key==`Name`]|[0].Value, Routes[].[DestinationCidrBlock, GatewayId || NatGatewayId || VpcPeeringConnectionId, State]]' \
  --output text
