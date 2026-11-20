#!/usr/bin/env bash
# Supprime toutes les piles d'un environnement, dans l'ordre inverse du deploiement.
#   Usage : scripts/supprimer.sh dev|prod
set -euo pipefail

ENV="${1:?Usage: $0 dev|prod}"
RACINE="$(cd "$(dirname "$0")/.." && pwd)"
REGION="${AWS_REGION:-eu-north-1}"
EQUIPE="$(jq -r .Equipe "$RACINE/parameters/$ENV.json")"
P="stack-leman-$ENV"

journal() { echo "[$(date -u +%H:%M:%S)] $*"; }

supprimer_pile() {
  local nom="$1" region="$2"
  if aws cloudformation describe-stacks --region "$region" --stack-name "$nom" >/dev/null 2>&1; then
    journal "Suppression de $nom"
    aws cloudformation delete-stack --region "$region" --stack-name "$nom"
    aws cloudformation wait stack-delete-complete --region "$region" --stack-name "$nom"
  else
    journal "$nom absente"
  fi
}

vider_bucket() { # le bucket des journaux ALB est versionne : supprimer toutes les versions
  local b
  b="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$P-00-socle" \
       --query "Stacks[0].Outputs[?OutputKey=='BucketJournauxAlb'].OutputValue | [0]" --output text 2>/dev/null || true)"
  [ -z "$b" ] || [ "$b" = "None" ] && return 0
  journal "Vidage du bucket $b"
  while :; do
    local lot
    lot="$(aws s3api list-object-versions --bucket "$b" --max-items 500 \
          --query '{Objects: [Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][] }' --output json)"
    [ "$(echo "$lot" | jq '.Objects | length')" -eq 0 ] && break
    aws s3api delete-objects --bucket "$b" --delete "$lot" >/dev/null
  done
}

START=$(date +%s)
supprimer_pile "$P-07-supervision"    "$REGION"
supprimer_pile "$P-06-edge-dns"       "$REGION"
supprimer_pile "$P-06a-waf"           us-east-1
supprimer_pile "$P-05-calcul"         "$REGION"
supprimer_pile "$P-04-interconnexion" "$REGION"
supprimer_pile "$P-03-pare-feu"       "$REGION"
supprimer_pile "$P-02-securite"       "$REGION"
supprimer_pile "$P-01-reseau"         "$REGION"
vider_bucket
supprimer_pile "$P-00-socle"          "$REGION"
supprimer_pile "$P-00b-budget"        us-east-1

# Les secrets sont mis en attente de suppression par CloudFormation : on les purge pour pouvoir recreer a l'identique
for s in vpn1-t1 vpn1-t2 vpn2-t1 vpn2-t2; do
  aws secretsmanager delete-secret --region "$REGION" --secret-id "psk-leman-$ENV-$EQUIPE-$s" \
    --force-delete-without-recovery >/dev/null 2>&1 || true
done
journal "Environnement $ENV supprime en $(( $(date +%s) - START )) s"
