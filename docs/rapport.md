# Rapport – Portail Léman en infrastructure as code

**Client :** Groupe Léman Finance SA (fictif) · **Prestataire :** Satom IT & Learning Solutions · **Équipe :** `af` · **Région :** eu-north-1

## Architecture
Le portail est décrit par 9 templates CloudFormation déployés en piles `stack-leman-<env>-*` : socle, réseau, sécurité, pare-feu, interconnexion, calcul, WAF, edge et DNS, supervision.
- **Réseau :** un VPC de prod sur 2 zones. Les sorties privées sont inspectées par Network Firewall, puis passent par la NAT.
- **Interconnexions :** un VPC dev relié par peering ou TGW. La TGW porte aussi 2 VPN IKEv2/BGP et une passerelle Direct Connect.
- **Publication :** ALB HTTPS, puis CloudFront protégé par WAF, puis Route 53 avec failover.
- **Supervision :** CloudWatch, SNS, Flow Logs chiffrés.

`dev` et `prod` sont issus des mêmes templates ; seuls les fichiers de [paramètres](../parameters) changent. Le détail est dans [architecture.md](architecture.md).

## Résultats des mesures
Les valeurs obtenues sont celles du dernier run de `tests/run-tests.sh`, conservé dans [preuves/](preuves/).

| Domaine | Indicateur | Seuil | Résultat |
|---|---|---|---|
| Sécurité | Findings critiques Security Hub | 0 | *voir preuves* |
| Sécurité | Ports d'administration exposés | 0 | 0 (cfn-guard + test dynamique) |
| Sécurité | Secrets dans le dépôt | 0 | 0 (gitleaks) |
| Connectivité | Tunnels VPN actifs | 2 sur 2 | 0 sur 2 (écart 1) |
| Connectivité | Chemin inter-VPC | conforme | dev → app via TGW, 22 bloqué |
| Connectivité | Résolution DNS | < 100 ms | *voir preuves* |
| Performance | TargetResponseTime p95 | < 500 ms | *voir preuves* |
| Performance | CacheHitRate statique | > 80 % | *voir preuves* |
| Performance | Charge nominale | 0 erreur 5xx | *voir preuves* |
| Monitoring | Alarme 5xx | notification < 5 min | *voir preuves* |
| Monitoring | Flux rejetés | détectés et expliqués | *voir preuves* |
| Coûts | Budget | < 80 % de 150 CHF | *voir preuves* |

## Écarts et actions correctives

| # | Écart | Cause | Action corrective |
|---|---|---|---|
| 1 | Tunnels VPN DOWN | Pairs `203.0.113.10` / `198.51.100.20` fictifs (plages de documentation) | Remplacer par les IP réelles des routeurs du siège et de l'agence ; strongSwan avec les pré-clés lues dans Secrets Manager |
| 2 | Certificat CloudFront us-east-1 et DNSSEC non actifs | `leman-finance.example` est réservé et non délégable | Acheter le domaine, puis renseigner `CertificatCloudFrontArn` et `CleKskKmsArn` (paramètres déjà prévus) |
| 3 | Origine CloudFront en HTTP 80 | Certificat ALB auto-signé | Certificat ACM public sur le vrai domaine, puis origine en `https-only` |
| 4 | Lien Direct Connect simulé | Pas d'opérateur ni de port physique | Commander la connexion et la VIF de transit ; la DXGW et l'association sont déjà en place |
| 5 | GuardDuty, Security Hub et Config non créés par la pile | Une seule instance par compte partagé | Paramètres `Creer*` à `true` sur un compte dédié |
| 6 | PR relues par moi-même | Travail en solo | Relecteur requis sur l'environnement `prod` ; en équipe, une approbation obligatoire sur `main` |
| 7 | Région eu-north-1 au lieu d'eu-central-2 | Région du compte de formation (Zurich non activée) | Activer eu-central-2 et changer `AWS_REGION` : aucun template à modifier |
| 8 | WAF CloudFront et budget non déployés | SCP du compte de formation : toute action en us-east-1 est refusée (`cloudformation:ValidateTemplate` en refus explicite) | Sur un compte du client, autoriser us-east-1 pour les piles globales : `06a-waf` et `00b-budget` sont prêtes, et la distribution reçoit l'ACL par paramètre |
| 9 | Amorce IAM hors pipeline | Prérequis de toute identité OIDC | Template versionné dans `bootstrap/`, déployé une fois |
