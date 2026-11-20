# Journal de projet – TP final DevSecOps

Chaque sprint livre un template, un contrôle de sécurité, une mesure et une preuve. Les preuves automatiques sont produites par `tests/run-tests.sh` dans [preuves/](preuves/) et dans le résumé du run GitHub Actions.

| Sprint | Template | Contrôle de sécurité | Mesure | Preuve | Statut |
|---|---|---|---|---|---|
| 1 – VPC et sous-réseaux | `01-reseau.yaml` | cfn-guard `prive_jamais_vers_igw` | `describe-subnets` : 6 sous-réseaux, `sub-public-1b` 10.x.5.0/24 en zone b | tests, section Réseau | ✅ |
| 2 – Routage | `01-reseau.yaml`, `03-pare-feu.yaml` | 0.0.0.0/0 des privés vers le pare-feu puis la NAT, jamais l'IGW | app-01 → dépôt de paquets (`dnf`) ; app-01 sans IP publique | tests, section Sortie | ✅ |
| 3 – SG et NACL | `02-securite.yaml` | cfn-guard `sg_aucun_port_administration_public` ; NACL deny 22 | Reachability Analyzer web → app : 8080 accessible, 22 bloqué | tests, section Chemins | ✅ |
| 4 – Network Firewall | `03-pare-feu.yaml` | Liste de domaines autorisés (TLS SNI, HTTP Host), journal ALERT chiffré KMS | `example.com` bloqué et consigné | tests, section Pare-feu | ✅ |
| 5 – Peering | `04-interconnexion.yaml` | Route limitée à 10.x.2.0/24 (app-01), aucune route par défaut | dev-01 → app-01:8080 ; dev-01 → web-01:22 refusé | tests (mode `peering`) | ✅ |
| 6 – Transit Gateway | `04-interconnexion.yaml` | Tables `rt-prod` / `rt-dev` / `rt-vpn` séparées, sans association par défaut | Chemin dev → prod via `tgw-` (Reachability Analyzer) | tests, section Chemins | ✅ |
| 7 – VPN | `04-interconnexion.yaml`, `00-socle.yaml` | IKEv2, pré-clés générées dans Secrets Manager (cfn-guard `precles_vpn_hors_template`) | `TunnelState`, télémétrie des tunnels | tests, section VPN | ⚠️ tunnels DOWN : pairs fictifs |
| 8 – Direct Connect | `04-interconnexion.yaml` | Préfixes annoncés filtrés (cfn-guard `dx_sans_route_par_defaut`) | Association `associated` ; `local-pref` et bascule simulés | tests + [procedures.md §4](procedures.md) | ✅ (lien simulé) |
| 9 – ALB | `05-calcul.yaml` | TLS 1.2 minimum, certificat ACM, journaux d'accès S3 (cfn-guard) | Charge sans 5xx, p95, panne simulée de web-01 | tests, sections Performance et Bascule | ✅ |
| 10 – Route 53 | `06-edge-dns.yaml` | Aucune IP privée en zone publique ; DNSSEC optionnel (clé KMS us-east-1) | `dig` interne et externe, bascule chronométrée | tests, section DNS | ✅ (DNSSEC : écart) |
| 11 – CloudFront | `06-edge-dns.yaml`, `06a-waf-us-east-1.yaml` | ALB:80 réservé au préfixe CloudFront, WAF (règles gérées + débit) | `x-cache` Hit, `CacheHitRate` | tests, section Cache | ✅ (certificat us-east-1 : écart) |
| 12 – Supervision | `07-supervision.yaml` | Flow Logs chiffrés KMS ; GuardDuty, Security Hub, Config (paramètres) | Alarme 5xx de bout en bout, flux rejetés | tests, section Supervision | ✅ |
| 13 – Automatisation | `.github/workflows/pipeline.yml`, `bootstrap/` | Rôle OIDC au moindre privilège, approbation avant prod, gitleaks | Pipeline au vert, `recreer-dev` | run GitHub Actions | ✅ |

## Décisions et incidents

| Date | Sujet | Décision |
|---|---|---|
| 20/11 | Compte AWS partagé entre apprenants | Suffixe `Equipe` dans tous les noms et exports ; GuardDuty, Security Hub, Config et OIDC (une instance par compte) activables par paramètre |
| 20/11 | Peering et TGW portent la même route dev ↔ prod | Paramètre `ModeInterDev` (peering \| tgw) : chaque sprint se démontre par un change set |
| 20/11 | Retour asymétrique via le pare-feu | NAT dans un sous-réseau dédié `sub-nat-1a` : prive → pare-feu → NAT, retour par `rt-nat` → pare-feu |
| 20/11 | Attachement TGW des VPN non exposé par CloudFormation | Ressource personnalisée Lambda en lecture seule |
| 20/11 | 503 des groupes cibles (module 9) | Groupes cibles sans Target Optimizer |
| 20/11 | Certificat ALB | Auto-signé importé dans ACM par le script (clé jamais versionnée) ; CloudFront contacte l'origine en HTTP 80 restreint au préfixe CloudFront |
| 20/11 | cfn-lint E3006 : `AWS::Budgets::Budget` inexistant en eu-central-2 | Budget déplacé dans `00b-budget-us-east-1.yaml`, déployé en us-east-1 |
| 20/11 | cfn-guard bloque la PR 4 (règle DX : valeur calculée comparée à une chaîne) | Règle corrigée : contrôle des valeurs littérales ; règle TLS limitée aux écouteurs HTTPS |
| 20/11 | Région | Le compte de formation travaille en eu-north-1 (eu-central-2 est une région à activer) : région changée par une seule variable `AWS_REGION` ; les templates sont indépendants de la région |
| 20/11 | OIDC refusé (`AccessDenied`) | CloudTrail : GitHub envoie le sujet `repo:<compte>@<id>/<depot>@<id>:…` (identifiants immuables) ; condition du rôle élargie aux deux formats |
| 20/11 | Étape 3 verte malgré un échec | `deployer.sh | tee` masquait le code de retour : pipeline en `shell: bash` (`-eo pipefail`) |
| 20/11 | SCP : us-east-1 interdit sur le compte | Piles globales (WAF, budget) marquées en écart sans bloquer le déploiement du portail |
| 20/11 | Quotas du compte partagé (IP Elastic, 5 NAT Gateway par zone) | IP Elastic du test animalux libérée ; zone de la NAT paramétrable (`ZoneNat`), NAT déplacée en zone c |
| 20/11 | Recréation à l'identique | `supprimer.sh` vide le bucket versionné et purge les secrets en attente de suppression |
