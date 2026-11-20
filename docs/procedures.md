# Procédures

## 1. Mise en place (une seule fois)

### 1.1 Amorce IAM (seul déploiement hors pipeline)
La pipeline a besoin d'une identité AWS. Elle est créée une seule fois depuis CloudShell, en `eu-north-1` :

```bash
# Le fournisseur OIDC GitHub n'existe qu'une fois par compte : vérifier s'il est déjà présent
aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?contains(Arn,'token.actions.githubusercontent.com')]"

aws cloudformation deploy --region eu-north-1 --stack-name stack-leman-bootstrap-af \
  --template-file bootstrap/iam-pipeline.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides Equipe=af ProprietaireGitHub=<compte-github> CreerFournisseurOidc=true \
  --tags Projet=SatomCloudNetwork Equipe=af Environnement=prod
aws cloudformation describe-stacks --region eu-north-1 --stack-name stack-leman-bootstrap-af --query 'Stacks[0].Outputs'
```

Si le fournisseur OIDC existe déjà, utiliser `CreerFournisseurOidc=false`. Si le compte de formation interdit la création de rôles IAM, voir la section 1.4.

### 1.2 Réglages GitHub
| Réglage | Valeur |
|---|---|
| Variables du dépôt (*Settings → Secrets and variables → Actions → Variables*) | `AWS_ROLE_ARN` = sortie `RolePipelineArn` ; `AWS_CFN_ROLE_ARN` = sortie `RoleExecutionCfnArn` ; `EMAIL_EXPLOITATION` = adresse de l'équipe d'exploitation |
| Environnements (*Settings → Environments*) | `dev` (sans protection) ; `prod` avec **Required reviewers** |
| Protection de `main` (*Settings → Branches*) | *Require a pull request before merging*, *Require status checks* : `1 - Lint`, `2 - Securite statique` ; pas de push direct |

Aucun secret n'est stocké dans GitHub : l'authentification passe par OIDC, et les pré-clés VPN sont générées par Secrets Manager.

### 1.3 Une pull request par sprint
```bash
git switch -c sprint-01-vpc
git add templates/01-reseau.yaml && git commit -m "Sprint 1 : VPC et sous-réseaux"
git push -u origin sprint-01-vpc
gh pr create --base main --title "Sprint 1 : VPC et sous-réseaux" --body "Template, contrôle, mesure : voir docs/journal-de-projet.md"
```
La PR déclenche le lint, cfn-guard, checkov et gitleaks. La fusion déclenche le déploiement dev, les tests, puis attend l'approbation pour la prod.

### 1.4 Repli sans droits IAM
Si l'amorce IAM est refusée, la pipeline exécute quand même les étapes 1 et 2 (lint, sécurité) sur chaque PR. Les étapes 3 à 5 sont sautées, car la variable `AWS_ROLE_ARN` est absente. Le **même script** est alors lancé depuis CloudShell, sur le commit fusionné de `main` :
```bash
git clone https://github.com/<compte>/satom-leman-portail && cd satom-leman-portail
EMAIL_EXPLOITATION=<adresse> bash scripts/deployer.sh dev && bash tests/run-tests.sh dev
```
Cet écart est consigné dans le rapport.

## 2. Démonstration (15 minutes)

| Minute | Action | Preuve |
|---|---|---|
| 0-2 | Montrer le dépôt, une PR relue et la pipeline au vert | Onglets *Pull requests* et *Actions* |
| 2-4 | Lancer *Actions → pipeline-devsecops → Run workflow → `recreer-dev`* | Suppression des piles `stack-leman-dev-*` dans l'ordre inverse |
| 4-10 | Pendant la recréation : expliquer l'architecture et les contrôles cfn-guard | [architecture.md](architecture.md), [securite.guard](../policies/securite.guard) |
| 10-13 | Tests automatiques : chemins Reachability Analyzer, cache, charge, alarme 5xx | Résumé du run (étape 4) |
| 13-15 | Notification SNS reçue, tableau de bord, flux rejetés dans Logs Insights | Mail et `db-portail-leman-dev-af` |

> La recréation complète dure environ 30 à 45 min, à cause du pare-feu, de la TGW, des VPN et de CloudFront. Pour une démonstration de 15 minutes, lancer `recreer-dev` juste avant la séance et présenter la fin du run.

## 3. Procédure de diagnostic

| Étape | Commande | Ce qu'on cherche |
|---|---|---|
| 1. Pile | `aws cloudformation describe-stack-events --stack-name stack-leman-dev-05-calcul --query "StackEvents[?contains(ResourceStatus,'FAILED')].[LogicalResourceId,ResourceStatusReason]"` | Première ressource en échec, quota, droit IAM |
| 2. Dérive | `aws cloudformation detect-stack-drift --stack-name …` | Modification faite à la console |
| 3. Chemin réseau | Reachability Analyzer (`tests/run-tests.sh`) | Composant bloquant : SG, NACL, route |
| 4. Flux | Logs Insights, requête `leman/dev-af/flux-rejetes` | `REJECT` : source, port |
| 5. Pare-feu | Journal `/leman/dev-af/pare-feu/alertes` | Domaine refusé |
| 6. Santé applicative | `aws elbv2 describe-target-health` | `unhealthy`, `unused` (instance arrêtée), Target Optimizer |

## 4. Direct Connect simulé et préférence de chemin
Une vraie connexion Direct Connect demande un opérateur et plusieurs semaines. La passerelle `dxgw-leman` est bien créée en IaC et associée à la TGW, avec des préfixes filtrés. Le lien lui-même est simulé hors AWS, avec FRRouting sur le routeur du siège : un tunnel GRE + BGP, où la route reçue par le « DX » est préférée grâce à `local-preference`.

```
router bgp 65010
 neighbor 172.16.0.1 remote-as 64513
 neighbor 172.16.0.1 route-map DX-IN in
route-map DX-IN permit 10
 set local-preference 200          ! DX préféré (VPN = 100 par défaut)
```
Bascule : quand le voisin DX tombe, la route DX disparaît et le trafic repasse par le VPN. Cette procédure a été validée au module 8 (bascule observée par le VPN), et elle est reprise ici telle quelle.
