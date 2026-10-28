# AWS Cloud Security Labs

Labs d'architecture et de sécurité réseau sur AWS, entièrement décrits en **Terraform** (Infrastructure as Code).
Réalisés dans le cadre de mon **M1 Cybersécurité**, sur un environnement AWS Academy Learner Lab (`us-east-1`).

Chaque lab suit la même démarche : **concevoir → déployer en IaC → prouver par des tests** (positifs *et* négatifs) → détruire.

---

## Labs

| Lab | Architecture | Thèmes sécurité |
|---|---|---|
| [**Multi-VPC secure network**](multi-vpc-secure-network/) | 4 VPC, 2 peerings, NAT Gateway, 7 instances | Segmentation, moindre privilège, NACL stateless vs SG stateful, contrôle des flux sortants (Squid), reverse proxy (HAProxy), bastion |
| [**Load balancer HA**](load-balancer/) | ALB sur 3 AZ, 3 reverse proxies Nginx, 3 serveurs Apache privés | Haute disponibilité, health checks, bascule automatique, Security Groups chaînés, serveurs sans IP publique |

---

## Compétences mises en œuvre

**Réseau cloud**
- VPC, sous-réseaux publics / privés / isolés, tables de routage explicites
- Internet Gateway, NAT Gateway, VPC Peering (non transitif, routes dans les deux sens)
- Application Load Balancer multi-AZ, health checks

**Sécurité**
- Moindre privilège : règles en `/32`, sortie par défaut des Security Groups supprimée
- Défense en profondeur : NACL + Security Group + ACL applicative
- Contrôle des sorties (egress filtering) via proxy Squid
- Accès administrateur par bastion unique + SSH ProxyJump (sans agent forwarding)
- Durcissement des instances : IMDSv2 obligatoire, volumes EBS chiffrés, AMI officielles via SSM

**Infrastructure as Code**
- Terraform : `for_each`, `count`, `locals`, `data sources`, `default_tags`, `user_data`
- Dépendances implicites et explicites (`depends_on`)
- Aucun secret dans le code : identifiants AWS hors dépôt, variables personnelles dans `terraform.tfvars` (ignoré)

---

## Prérequis

- Compte AWS (ou AWS Academy Learner Lab), région `us-east-1`
- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.5
- AWS CLI v2 configurée (`aws sts get-caller-identity`)
- Une paire de clés EC2 (`vockey` dans le Learner Lab)

## Utilisation

```bash
cd multi-vpc-secure-network          # ou load-balancer
cp terraform.tfvars.example terraform.tfvars
# renseigner son IP publique : curl -s https://checkip.amazonaws.com
terraform init
terraform plan                       # relire le plan avant d'appliquer
terraform apply
# ... tests ...
terraform destroy
```

> ⚠️ **Coûts** : ces labs créent des ressources facturées à l'heure (NAT Gateway, ALB, instances EC2).
> Toujours exécuter `terraform destroy` à la fin.

---

## Ce qui n'est pas dans ce dépôt

| Fichier | Raison |
|---|---|
| `terraform.tfstate*` | Contient l'état complet de l'infrastructure (IP, identifiants, ARN) |
| `terraform.tfvars` | Valeurs personnelles (IP publique) — voir `terraform.tfvars.example` |
| `.terraform/` | Provider téléchargé par `terraform init` |
| `*.pem` | Clés privées |

Le fichier `.terraform.lock.hcl` est en revanche versionné : il fige les versions des providers.

---

## Pistes d'amélioration

- HTTPS (ACM + ALB / HAProxy) et AWS WAF
- VPC Flow Logs et alertes CloudWatch
- AWS Systems Manager Session Manager à la place des bastions SSH
- Une NAT Gateway par zone de disponibilité
- Scan IaC en CI (Checkov / tfsec) via GitHub Actions
- Backend Terraform distant (S3 chiffré + verrouillage)

---

**Auteur** : Koceila HABAREK — Cybersécurité
