#!/usr/bin/env bash
# Deploie le portail Leman pour un environnement, toujours via des change sets (aws cloudformation deploy).
# Utilise par la pipeline ET, si la pipeline n'a pas de droits AWS, depuis CloudShell (meme script, memes fichiers).
#   Usage : scripts/deployer.sh dev|prod
# Variables optionnelles : AWS_REGION (defaut eu-central-2), AWS_CFN_ROLE_ARN (role d'execution CloudFormation),
#                          EMAIL_EXPLOITATION (abonnement SNS et budget, jamais ecrit dans le depot)
set -euo pipefail

ENV="${1:?Usage: $0 dev|prod}"
RACINE="$(cd "$(dirname "$0")/.." && pwd)"
REGION="${AWS_REGION:-eu-central-2}"
FICHIER_PARAMS="$RACINE/parameters/$ENV.json"
[ -f "$FICHIER_PARAMS" ] || { echo "Fichier de parametres introuvable : $FICHIER_PARAMS"; exit 1; }

EQUIPE="$(jq -r .Equipe "$FICHIER_PARAMS")"
declare -A VAL
while IFS='=' read -r k v; do VAL[$k]="$v"; done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' "$FICHIER_PARAMS")
VAL[EmailExploitation]="${EMAIL_EXPLOITATION:-}"

ROLE_OPT=()
[ -n "${AWS_CFN_ROLE_ARN:-}" ] && ROLE_OPT=(--role-arn "$AWS_CFN_ROLE_ARN")
TAGS=(Projet=SatomCloudNetwork "Equipe=$EQUIPE" "Environnement=$ENV")

journal() { echo "[$(date -u +%H:%M:%S)] $*"; }

# ---------- Prerequis : valeurs calculees, aucune saisie manuelle ----------
prerequis() {
  journal "Recherche de la liste de prefixes CloudFront ($REGION)"
  VAL[PrefixListCloudFront]="$(aws ec2 describe-managed-prefix-lists --region "$REGION" \
    --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
    --query 'PrefixLists[0].PrefixListId' --output text)"
  [ "${VAL[PrefixListCloudFront]}" = "None" ] && VAL[PrefixListCloudFront]=""

  local cn="alb-$ENV-$EQUIPE.leman.internal"
  journal "Certificat de l'ALB ($cn)"
  local arn
  arn="$(aws acm list-certificates --region "$REGION" --includes keyTypes=RSA_2048 \
        --query "CertificateSummaryList[?DomainName=='$cn'].CertificateArn | [0]" --output text)"
  if [ -z "$arn" ] || [ "$arn" = "None" ]; then
    local tmp; tmp="$(mktemp -d)"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -subj "/CN=$cn/O=Satom IT/C=CH" \
      -keyout "$tmp/cle.pem" -out "$tmp/cert.pem" 2>/dev/null
    arn="$(aws acm import-certificate --region "$REGION" --certificate "fileb://$tmp/cert.pem" \
      --private-key "fileb://$tmp/cle.pem" \
      --tags Key=Projet,Value=SatomCloudNetwork "Key=Equipe,Value=$EQUIPE" "Key=Environnement,Value=$ENV" \
      --query CertificateArn --output text)"
    rm -rf "$tmp"      # la cle privee ne quitte jamais l'execution et n'est jamais versionnee
  fi
  VAL[CertificatAlbArn]="$arn"
}

# ---------- Deploiement d'une pile (change set cree, verifie et execute par 'deploy') ----------
deployer_pile() {
  local nom="$1" modele="$2" region="$3"
  local cles overrides=()
  cles="$(aws cloudformation validate-template --region "$region" --template-body "file://$modele" \
          --query 'Parameters[].ParameterKey' --output text)"
  for k in $cles; do
    if [ -n "${VAL[$k]+x}" ]; then overrides+=("$k=${VAL[$k]}"); fi
  done
  journal "Deploiement de $nom ($region)"
  aws cloudformation deploy --region "$region" --stack-name "$nom" --template-file "$modele" \
    --parameter-overrides "${overrides[@]}" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
    --tags "${TAGS[@]}" --no-fail-on-empty-changeset "${ROLE_OPT[@]}"
}

sortie() { # sortie <pile> <region> <cle>
  aws cloudformation describe-stacks --region "$2" --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$3'].OutputValue | [0]" --output text
}

prerequis
P="stack-leman-$ENV"
deployer_pile "$P-00-socle"         "$RACINE/templates/00-socle.yaml"          "$REGION"
deployer_pile "$P-00b-budget"       "$RACINE/templates/00b-budget-us-east-1.yaml" "us-east-1"
deployer_pile "$P-01-reseau"        "$RACINE/templates/01-reseau.yaml"         "$REGION"
deployer_pile "$P-02-securite"      "$RACINE/templates/02-securite.yaml"       "$REGION"
deployer_pile "$P-03-pare-feu"      "$RACINE/templates/03-pare-feu.yaml"       "$REGION"
deployer_pile "$P-04-interconnexion" "$RACINE/templates/04-interconnexion.yaml" "$REGION"
deployer_pile "$P-05-calcul"        "$RACINE/templates/05-calcul.yaml"         "$REGION"
deployer_pile "$P-06a-waf"          "$RACINE/templates/06a-waf-us-east-1.yaml" "us-east-1"
VAL[AclWebArn]="$(sortie "$P-06a-waf" us-east-1 AclWebArn)"
deployer_pile "$P-06-edge-dns"      "$RACINE/templates/06-edge-dns.yaml"       "$REGION"
deployer_pile "$P-07-supervision"   "$RACINE/templates/07-supervision.yaml"    "$REGION"

journal "Portail $ENV deploye"
echo "ALB        : https://$(sortie "$P-05-calcul" "$REGION" AlbDns)"
echo "CloudFront : https://$(sortie "$P-06-edge-dns" "$REGION" DomaineCloudFront)"
echo "DNS public : $(sortie "$P-06-edge-dns" "$REGION" ServeursNoms)"
