# satom-leman-portail

Portail de **Groupe Léman Finance SA** reconstruit en *infrastructure as code* (AWS CloudFormation). C'est le TP final DevSecOps de la mission Satom Cloud Network.

Le dépôt est la **source unique** : chaque ressource est décrite dans un template versionné, relue en *pull request*, contrôlée par la pipeline, puis déployée par des *change sets*. Aucune ressource n'est créée à la main ; seule l'amorce IAM ([bootstrap](bootstrap/iam-pipeline.yaml)) se déploie une fois.

| Élément | Choix |
|---|---|
| IaC | AWS CloudFormation, un template par domaine |
| Région | `eu-north-1` (Stockholm, région du compte de formation ; la consigne indique eu-central-2) ; WAF CloudFront et budget en `us-east-1` |
| Environnements | `dev` puis `prod` : mêmes templates, paramètres séparés, piles distinctes `stack-leman-<env>-*` |
| Tags obligatoires | `Projet=SatomCloudNetwork`, `Equipe=af`, `Environnement=<dev\|prod>` (dans les templates et sur chaque pile) |
| Budget | 150 CHF (165 USD), alerte à 80 % |

## Arborescence

```
satom-leman-portail/
├── templates/            # un YAML par domaine
│   ├── 00-socle.yaml             KMS, journaux ALB (S3), SNS, pré-clés VPN (Secrets Manager)
│   ├── 00b-budget-us-east-1.yaml budget 150 CHF, alerte à 80 % (ressource globale, déployée en us-east-1)
│   ├── 01-reseau.yaml            sprints 1-2 : VPC, sous-réseaux 2 AZ, IGW, NAT, tables de routage
│   ├── 02-securite.yaml          sprint 3 : Security Groups, NACL
│   ├── 03-pare-feu.yaml          sprint 4 : Network Firewall (liste de domaines), routage d'inspection
│   ├── 04-interconnexion.yaml    sprints 5-8 : VPC dev, peering, Transit Gateway, 2 VPN IKEv2/BGP, DXGW
│   ├── 05-calcul.yaml            sprint 9 : web-01, app-01, groupes cibles, ALB HTTPS
│   ├── 06a-waf-us-east-1.yaml    sprint 11 : AWS WAF (règles gérées + limitation de débit)
│   ├── 06-edge-dns.yaml          sprints 10-11 : CloudFront, Route 53 public/privé, contrôle de santé, failover
│   └── 07-supervision.yaml       sprint 12 : Flow Logs KMS, alarmes, tableau de bord, GuardDuty/Security Hub/Config
├── parameters/           # dev.json, prod.json (aucun secret)
├── policies/             # règles cfn-guard (bloquantes)
├── tests/                # run-tests.sh (connectivité, sécurité, performance, alerte) + charge.py
├── scripts/              # deployer.sh, supprimer.sh (utilisés par la pipeline)
├── bootstrap/            # rôle OIDC de la pipeline + rôle d'exécution CloudFormation
├── docs/                 # journal de projet, architecture, rapport, procédures, preuves
└── .github/workflows/    # pipeline DevSecOps
```

## Pipeline (5 étapes, dans l'ordre)

1. **Lint** : `cfn-lint` sur chaque template et `shellcheck` sur les scripts. Une erreur bloque la PR.
2. **Sécurité statique** : `cfn-guard` avec [policies/securite.guard](policies/securite.guard) (bloquant), `checkov` (rapport SARIF) et `gitleaks` (secrets, bloquant).
3. **Déploiement dev** : `scripts/deployer.sh dev`, avec un change set par pile.
4. **Tests** : `tests/run-tests.sh dev`. Les preuves sont publiées dans le résumé du run et en artefact.
5. **Déploiement prod** : uniquement après l'approbation d'un relecteur, via l'environnement GitHub `prod`.

## Démarrage rapide

Voir [docs/procedures.md](docs/procedures.md) : amorçage IAM, réglages GitHub, démonstration de 15 minutes, diagnostic.

```bash
# Déploiement (pipeline ou CloudShell, même script)
bash scripts/deployer.sh dev
bash tests/run-tests.sh dev
bash scripts/supprimer.sh dev
```

## Documentation

- [Architecture](docs/architecture.md)
- [Journal de projet](docs/journal-de-projet.md), avec une entrée par sprint
- [Rapport d'une page](docs/rapport.md) : architecture, mesures, écarts et actions correctives
- [Procédures](docs/procedures.md)
- [Preuves](docs/preuves/)
