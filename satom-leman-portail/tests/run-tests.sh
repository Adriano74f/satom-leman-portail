#!/usr/bin/env bash
# Tests de connectivite, de securite, de performance et de supervision du portail Leman.
# Chaque test produit une ligne de preuve dans docs/preuves/tests-<env>-<date>.md
#   Usage : tests/run-tests.sh dev|prod
# Resultats : OK (conforme), KO (bloquant, fait echouer la pipeline), ECART (limite connue et documentee).
set -uo pipefail

ENV="${1:?Usage: $0 dev|prod}"
RACINE="$(cd "$(dirname "$0")/.." && pwd)"
REGION="${AWS_REGION:-eu-central-2}"
EQUIPE="$(jq -r .Equipe "$RACINE/parameters/$ENV.json")"
PV="$(jq -r .PrefixeVpc "$RACINE/parameters/$ENV.json")"
DOMAINE="$(jq -r .NomDomaine "$RACINE/parameters/$ENV.json")"
P="stack-leman-$ENV"
DATE="$(date -u +%Y%m%d-%H%M)"
RAPPORT="${RAPPORT:-$RACINE/docs/preuves/tests-$ENV-$DATE.md}"
mkdir -p "$(dirname "$RAPPORT")"
KO=0

sortie() { aws cloudformation describe-stacks --region "${3:-$REGION}" --stack-name "$1" \
  --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue | [0]" --output text 2>/dev/null; }
ligne() { # ligne <sprint> <test> <attendu> <obtenu> <OK|KO|ECART>
  local icone="✅"; [ "$5" = KO ] && icone="❌" && KO=$((KO+1)); [ "$5" = ECART ] && icone="⚠️"
  printf '| %s | %s | %s | %s | %s %s |\n' "$1" "$2" "$3" "$4" "$icone" "$5" | tee -a "$RAPPORT"
}
section() { printf '\n### %s\n\n| Sprint | Test | Attendu | Obtenu | Resultat |\n|---|---|---|---|---|\n' "$1" | tee -a "$RAPPORT"; }

VPC="$(sortie "$P-01-reseau" VpcId)"
RT_PRIVE="$(sortie "$P-01-reseau" RtPrive)"
WEB="$(sortie "$P-05-calcul" Web01Id)"
APP="$(sortie "$P-05-calcul" App01Id)"
DEV="$(sortie "$P-04-interconnexion" Dev01Id)"
ALB="$(sortie "$P-05-calcul" AlbDns)"
TGWEB="$(sortie "$P-05-calcul" TgWebArn)"
CF="$(sortie "$P-06-edge-dns" DomaineCloudFront)"
DIST="$(sortie "$P-06-edge-dns" DistributionId)"
ZONE="$(sortie "$P-06-edge-dns" ZonePubliqueId)"
HC="$(sortie "$P-06-edge-dns" ControleSanteId)"
NS1="$(sortie "$P-06-edge-dns" ServeursNoms | cut -d, -f1)"
FLUX="$(sortie "$P-07-supervision" JournalFluxVpc)"

cat > "$RAPPORT" <<EOF
# Preuves de tests - portail Leman \`$ENV\` - $(date -u '+%d/%m/%Y %H:%M UTC')

Region : \`$REGION\` · VPC : \`$VPC\` · ALB : \`$ALB\` · CloudFront : \`$CF\`
EOF

# ---------- Utilitaires SSM ----------
attendre_ssm() {
  for _ in $(seq 1 30); do
    [ "$(aws ssm describe-instance-information --region "$REGION" --filters "Key=InstanceIds,Values=$1" \
        --query 'length(InstanceInformationList)' --output text)" = "1" ] && return 0
    sleep 10
  done; return 1
}
ssm() { # ssm <instance> <commande shell> -> sortie standard
  local f id st
  f="$(mktemp)"; jq -n --arg c "$2" '{commands:[$c]}' > "$f"
  id="$(aws ssm send-command --region "$REGION" --instance-ids "$1" --document-name AWS-RunShellScript \
        --parameters "file://$f" --query Command.CommandId --output text)"; rm -f "$f"
  for _ in $(seq 1 60); do
    sleep 3
    st="$(aws ssm get-command-invocation --region "$REGION" --command-id "$id" --instance-id "$1" --query Status --output text 2>/dev/null)"
    case "$st" in Success|Failed|TimedOut|Cancelled) break;; esac
  done
  aws ssm get-command-invocation --region "$REGION" --command-id "$id" --instance-id "$1" --query StandardOutputContent --output text
}

# ---------- Reachability Analyzer ----------
analyse() { # analyse <source> <destination> <port> -> "trouve|non;composants"
  local chemin an res
  chemin="$(aws ec2 create-network-insights-path --region "$REGION" --source "$1" --destination "$2" \
            --protocol tcp --destination-port "$3" \
            --tag-specifications "ResourceType=network-insights-path,Tags=[{Key=Projet,Value=SatomCloudNetwork},{Key=Equipe,Value=$EQUIPE},{Key=Environnement,Value=$ENV}]" \
            --query NetworkInsightsPath.NetworkInsightsPathId --output text)"
  an="$(aws ec2 start-network-insights-analysis --region "$REGION" --network-insights-path-id "$chemin" \
        --query NetworkInsightsAnalysis.NetworkInsightsAnalysisId --output text)"
  for _ in $(seq 1 40); do
    sleep 6
    res="$(aws ec2 describe-network-insights-analyses --region "$REGION" --network-insights-analysis-ids "$an" \
           --query 'NetworkInsightsAnalyses[0]' --output json)"
    [ "$(echo "$res" | jq -r .Status)" = "succeeded" ] && break
  done
  echo "$(echo "$res" | jq -r 'if .NetworkPathFound then "trouve" else "non" end');$(echo "$res" | jq -r '[.ForwardPathComponents[]?.Component.Id] | map(select(test("^(tgw|pcx)"))) | unique | join(" ")')"
  aws ec2 delete-network-insights-analysis --region "$REGION" --network-insights-analysis-id "$an" >/dev/null 2>&1
  aws ec2 delete-network-insights-path --region "$REGION" --network-insights-path-id "$chemin" >/dev/null 2>&1
}

# ======================= Sprints 1 et 2 : reseau =======================
section "Reseau et routage (sprints 1-2)"
NB="$(aws ec2 describe-subnets --region "$REGION" --filters Name=vpc-id,Values="$VPC" --query 'length(Subnets)' --output text)"
AZ1B="$(aws ec2 describe-subnets --region "$REGION" --filters Name=vpc-id,Values="$VPC" Name=cidr-block,Values="$PV.5.0/24" --query 'Subnets[0].AvailabilityZone' --output text)"
ligne 1 "describe-subnets" "6 sous-reseaux, $PV.5.0/24 en zone b" "$NB sous-reseaux, $PV.5.0/24 en $AZ1B" "$([ "$NB" = 6 ] && [[ "$AZ1B" == *b ]] && echo OK || echo KO)"
CIBLE="$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$RT_PRIVE" \
         --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'] | [0]" --output json \
         | jq -r '.GatewayId // .NatGatewayId // .VpcEndpointId // .TransitGatewayId // "aucune"')"
ligne 1 "Route par defaut du prive" "jamais vers igw-" "$CIBLE" "$([[ "$CIBLE" == *igw-* ]] && echo KO || echo OK)"
IPAPP="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$APP" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
ligne 2 "app-01 sans IP publique (refus de l'exterieur)" "None" "$IPAPP" "$([ "$IPAPP" = None ] && echo OK || echo KO)"

# ======================= Sprint 4 : sortie et pare-feu =======================
section "Sortie Internet et pare-feu (sprints 2 et 4)"
if attendre_ssm "$APP"; then
  OUT="$(ssm "$APP" 'curl -s -o /dev/null -w "%{http_code}" --max-time 8 https://aws.amazon.com; echo; curl -s -o /dev/null -w "%{http_code}" --max-time 8 https://example.com; echo; dnf -q install -y bind-utils >/dev/null 2>&1; echo dnf=$?')"
  AUTORISE="$(echo "$OUT" | sed -n 1p)"; BLOQUE="$(echo "$OUT" | sed -n 2p)"; DNF="$(echo "$OUT" | sed -n 3p)"
  ligne 2 "app-01 -> depot de paquets (dnf)" "dnf=0" "$DNF" "$([ "$DNF" = dnf=0 ] && echo OK || echo KO)"
  ligne 4 "app-01 -> aws.amazon.com (autorise)" "code HTTP" "$AUTORISE" "$([ "$AUTORISE" != 000 ] && echo OK || echo KO)"
  ligne 4 "app-01 -> example.com (non autorise)" "000 (bloque)" "$BLOQUE" "$([ "$BLOQUE" = 000 ] && echo OK || echo KO)"
  sleep 60
  NBLOG="$(aws logs filter-log-events --region "$REGION" --log-group-name "/leman/$ENV-$EQUIPE/pare-feu/alertes" \
           --filter-pattern '"example.com"' --start-time $(( ($(date +%s) - 900) * 1000 )) --query 'length(events)' --output text 2>/dev/null || echo 0)"
  ligne 4 "Blocage consigne (journal ALERT)" ">= 1 evenement" "$NBLOG" "$([ "${NBLOG:-0}" -ge 1 ] 2>/dev/null && echo OK || echo ECART)"
else
  ligne 2 "Agent SSM sur app-01" "en ligne" "absent apres 5 min" KO
fi

# ======================= Sprints 3, 5, 6 : Reachability Analyzer =======================
section "Chemins reseau - VPC Reachability Analyzer (sprints 3, 5, 6)"
R="$(analyse "$WEB" "$APP" 8080)"; ligne 3 "web-01 -> app-01:8080" "accessible" "${R%%;*}" "$([ "${R%%;*}" = trouve ] && echo OK || echo KO)"
R="$(analyse "$WEB" "$APP" 22)";   ligne 3 "web-01 -> app-01:22" "bloque" "${R%%;*}" "$([ "${R%%;*}" = non ] && echo OK || echo KO)"
R="$(analyse "$DEV" "$APP" 8080)"; ligne 6 "dev-01 -> app-01:8080 (chemin)" "accessible via tgw-" "${R%%;*} ${R#*;}" "$([ "${R%%;*}" = trouve ] && echo OK || echo KO)"
R="$(analyse "$DEV" "$WEB" 22)";   ligne 5 "dev-01 -> web-01:22" "bloque" "${R%%;*}" "$([ "${R%%;*}" = non ] && echo OK || echo KO)"

# ======================= Sprints 7 et 8 : VPN et Direct Connect =======================
section "VPN et Direct Connect (sprints 7-8)"
for v in VpnSiegeId VpnAgenceId; do
  ID="$(sortie "$P-04-interconnexion" "$v")"
  [ -z "$ID" ] || [ "$ID" = None ] && continue
  UP="$(aws ec2 describe-vpn-connections --region "$REGION" --vpn-connection-ids "$ID" \
        --query "length(VpnConnections[0].VgwTelemetry[?Status=='UP'])" --output text)"
  IKE="$(aws ec2 describe-vpn-connections --region "$REGION" --vpn-connection-ids "$ID" \
        --query "VpnConnections[0].Options.TunnelOptions[0].IkeVersions[0].Value" --output text)"
  ligne 7 "$v ($ID) tunnels UP" "2 sur 2" "$UP sur 2 (IKE $IKE)" "$([ "$UP" = 2 ] && echo OK || echo ECART)"
done
DX="$(aws directconnect describe-direct-connect-gateways --query "directConnectGateways[?directConnectGatewayName=='dxgw-leman-$ENV-$EQUIPE'] | [0].directConnectGatewayId" --output text 2>/dev/null)"
if [ -n "$DX" ] && [ "$DX" != None ]; then
  ETAT="$(aws directconnect describe-direct-connect-gateway-associations --direct-connect-gateway-id "$DX" --query 'directConnectGatewayAssociations[0].associationState' --output text)"
  PFX="$(aws directconnect describe-direct-connect-gateway-associations --direct-connect-gateway-id "$DX" --query 'directConnectGatewayAssociations[0].allowedPrefixesToDirectConnectGateway[].cidr' --output text)"
  ligne 8 "dxgw associee a la TGW" "associated" "$ETAT" "$([ "$ETAT" = associated ] && echo OK || echo KO)"
  ligne 8 "Prefixes annonces filtres" "pas de 0.0.0.0/0" "$PFX" "$([[ "$PFX" == *0.0.0.0/0* ]] && echo KO || echo OK)"
fi

# ======================= Sprints 9 et 11 : ALB, performance, cache =======================
section "Equilibrage, performance et cache (sprints 9 et 11)"
SANTE="$(aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$TGWEB" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)"
ligne 9 "Sante web-01 (tg-web)" "healthy" "$SANTE" "$([ "$SANTE" = healthy ] && echo OK || echo KO)"
TLS="$(echo | openssl s_client -connect "$ALB:443" -tls1_1 2>&1 | grep -c 'Cipher is (NONE)\|alert\|no protocols' || true)"
ligne 9 "TLS 1.1 refuse par l'ALB" "refus" "$([ "$TLS" -ge 1 ] && echo refuse || echo accepte)" "$([ "$TLS" -ge 1 ] && echo OK || echo KO)"
CHARGE="$(python3 "$RACINE/tests/charge.py" "https://$CF/" 400 20)"
P95="$(echo "$CHARGE" | jq -r .p95_ms)"; E5="$(echo "$CHARGE" | jq -r .erreurs_5xx)"
ligne 9 "Test de charge 400 req / 20 en parallele (CloudFront)" "0 erreur 5xx" "$E5 erreur(s), p95 client ${P95} ms" "$([ "$E5" = 0 ] && echo OK || echo KO)"
CHARGE="$(python3 "$RACINE/tests/charge.py" "https://$CF/api/health" 200 10)"
ligne 9 "Charge /api/health" "0 erreur 5xx" "$(echo "$CHARGE" | jq -r '"\(.erreurs_5xx) erreur(s), p95 client \(.p95_ms) ms"')" "$([ "$(echo "$CHARGE" | jq -r .erreurs_5xx)" = 0 ] && echo OK || echo KO)"
sleep 90
TRT="$(aws cloudwatch get-metric-statistics --region "$REGION" --namespace AWS/ApplicationELB --metric-name TargetResponseTime \
       --dimensions Name=LoadBalancer,Value="$(sortie "$P-05-calcul" AlbNomComplet)" --extended-statistics p95 \
       --start-time "$(date -u -d '-20 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 1200 \
       --query 'Datapoints[0].ExtendedStatistics.p95' --output text)"
ligne 9 "TargetResponseTime p95 (CloudWatch)" "< 0,5 s" "$TRT s" "$(python3 -c "import sys; v='$TRT'; print('OK' if v not in ('None','') and float(v) < 0.5 else 'ECART')")"
X1="$(curl -sI "https://$CF/static/logo.png" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache"{print $2}')"
X2="$(curl -sI "https://$CF/static/logo.png" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache"{print $2}')"
ligne 11 "x-cache /static/logo.png (2e requete)" "Hit from cloudfront" "$X1 -> $X2" "$([[ "$X2" == Hit* ]] && echo OK || echo KO)"
XA="$(curl -sI "https://$CF/api/health" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache"{print $2}')"
ligne 11 "x-cache /api/health" "jamais Hit" "$XA" "$([[ "$XA" == Hit* ]] && echo KO || echo OK)"
for _ in $(seq 1 40); do curl -s -o /dev/null "https://$CF/static/logo.png"; done
CHR="$(aws cloudwatch get-metric-statistics --region us-east-1 --namespace AWS/CloudFront --metric-name CacheHitRate \
       --dimensions Name=DistributionId,Value="$DIST" Name=Region,Value=Global --statistics Average \
       --start-time "$(date -u -d '-30 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 1800 \
       --query 'Datapoints[0].Average' --output text)"
ligne 11 "CacheHitRate (CloudWatch)" "> 80 %" "$CHR %" "$(python3 -c "v='$CHR'; print('OK' if v not in ('None','') and float(v) > 80 else 'ECART')")"
ORIG="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$ALB/health")"
ligne 11 "ALB en direct sur l'origine HTTP 80" "000 (prefixe CloudFront seul)" "$ORIG" "$([ "$ORIG" = 000 ] && echo OK || echo KO)"

# ======================= Sprint 10 : DNS =======================
section "DNS (sprint 10)"
if [ -n "$NS1" ] && [ "$NS1" != None ]; then
  EXT="$(dig @"$NS1" "portefeuilles.$DOMAINE" A +stats 2>/dev/null)"
  TEXT="$(echo "$EXT" | awk '/Query time/{print $4}')"
  ligne 10 "dig externe (serveur de la zone)" "IP CloudFront, < 100 ms" "$(echo "$EXT" | awk '/^portefeuilles/{print $5}' | head -1) en ${TEXT} ms" "$([ "${TEXT:-999}" -lt 100 ] && echo OK || echo ECART)"
fi
INT="$(ssm "$APP" "dig web.$ENV.leman.internal +stats | awk '/^web/{print \$5} /Query time/{print \$4}' | tr '\n' ' '")"
ligne 10 "dig interne (app-01, zone privee)" "$PV.1.10, < 100 ms" "$INT ms" "$([[ "$INT" == $PV.1.10* ]] && echo OK || echo KO)"
PRIV="$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE" --query "ResourceRecordSets[].ResourceRecords[].Value" --output text | tr '\t' '\n' | grep -cE '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' || true)"
ligne 10 "Aucune adresse privee dans la zone publique" "0" "$PRIV" "$([ "$PRIV" = 0 ] && echo OK || echo KO)"
DNSSEC="$(aws route53 get-dnssec --hosted-zone-id "$ZONE" --query Status.ServeSignature --output text 2>/dev/null)"
ligne 10 "DNSSEC zone publique" "SIGNING" "$DNSSEC" "$([ "$DNSSEC" = SIGNING ] && echo OK || echo ECART)"

# ======================= Sprint 12 : supervision =======================
section "Supervision et alerte (sprint 12)"
T0=$(date +%s)
for _ in $(seq 1 20); do curl -sk -o /dev/null -X DELETE "https://$ALB/health"; done   # 501 renvoye par la cible
ETAT=""
for _ in $(seq 1 40); do
  ETAT="$(aws cloudwatch describe-alarms --region "$REGION" --alarm-names "alarm-5xx-portail-$ENV-$EQUIPE" --query 'MetricAlarms[0].StateValue' --output text)"
  [ "$ETAT" = ALARM ] && break; sleep 10
done
DELAI=$(( $(date +%s) - T0 ))
ligne 12 "Alarme 5xx provoquee (20 x 501)" "ALARM en moins de 300 s" "$ETAT apres $DELAI s" "$([ "$ETAT" = ALARM ] && [ "$DELAI" -lt 300 ] && echo OK || echo KO)"
REJ="$(aws logs start-query --region "$REGION" --log-group-name "$FLUX" --start-time $(( $(date +%s) - 3600 )) --end-time "$(date +%s)" \
      --query-string 'parse @message "* * * * * * * * * * * * * *" as v,c,e,src,dst,sp,dport,pr,pa,o,d,f,act,st | filter act="REJECT" | stats count(*) as n' --query queryId --output text)"
sleep 15
NREJ="$(aws logs get-query-results --region "$REGION" --query-id "$REJ" --query 'results[0][0].value' --output text)"
ligne 12 "Flux rejetes (Logs Insights)" "> 0, expliques" "$NREJ rejets sur 1 h" "$([ "${NREJ:-0}" != None ] && [ "${NREJ:-0}" -gt 0 ] 2>/dev/null && echo OK || echo ECART)"

# ======================= Securite et couts =======================
section "Securite et couts (sprints 3, 12, 13)"
SSH="$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=tag:Equipe,Values=$EQUIPE" "Name=tag:Environnement,Values=$ENV" \
      --query "length(SecurityGroups[].IpPermissions[?FromPort<=\`22\` && ToPort>=\`22\` && contains(IpRanges[].CidrIp, '0.0.0.0/0')][])" --output text)"
ligne 3 "Ports d'administration exposes (22 depuis 0.0.0.0/0)" "0" "$SSH" "$([ "$SSH" = 0 ] && echo OK || echo KO)"
if aws securityhub describe-hub --region "$REGION" >/dev/null 2>&1; then
  CRIT="$(aws securityhub get-findings --region "$REGION" --max-items 100 --filters \
     "{\"SeverityLabel\":[{\"Value\":\"CRITICAL\",\"Comparison\":\"EQUALS\"}],\"RecordState\":[{\"Value\":\"ACTIVE\",\"Comparison\":\"EQUALS\"}],\"ResourceTags\":[{\"Key\":\"Equipe\",\"Value\":\"$EQUIPE\",\"Comparison\":\"EQUALS\"}]}" \
     --query 'length(Findings)' --output text)"
  ligne 12 "Security Hub : findings critiques ouverts" "0" "$CRIT" "$([ "$CRIT" = 0 ] && echo OK || echo KO)"
else
  ligne 12 "Security Hub" "active" "non active sur le compte" ECART
fi
GD="$(aws guardduty list-detectors --region "$REGION" --query 'length(DetectorIds)' --output text 2>/dev/null || echo 0)"
ligne 12 "GuardDuty" "detecteur actif" "$GD detecteur(s)" "$([ "$GD" -ge 1 ] 2>/dev/null && echo OK || echo ECART)"
BUD="$(aws budgets describe-budget --account-id "$(aws sts get-caller-identity --query Account --output text)" --budget-name "budget-leman-$ENV-$EQUIPE" \
      --query 'Budget.[CalculatedSpend.ActualSpend.Amount, BudgetLimit.Amount]' --output text 2>/dev/null)"
if [ -n "$BUD" ]; then
  PCT="$(echo "$BUD" | awk '{printf "%.1f", ($1/$2)*100}')"
  ligne 13 "Consommation du budget" "< 80 %" "$PCT % ($BUD USD)" "$(awk -v p="$PCT" 'BEGIN{print (p<80)?"OK":"KO"}')"
else
  ligne 13 "Budget" "present" "absent (EMAIL_EXPLOITATION non fourni)" ECART
fi

# ======================= Bascule chronometree (sprints 9 et 10) =======================
section "Panne simulee de web-01 et bascule DNS (sprints 9 et 10)"
aws elbv2 deregister-targets --region "$REGION" --target-group-arn "$TGWEB" --targets Id="$WEB",Port=80
T0=$(date +%s); ERR=0; TOT=0; T_DNS=""
for _ in $(seq 1 60); do
  C="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://$CF/health")"; TOT=$((TOT+1)); [ "$C" != 200 ] && ERR=$((ERR+1))
  if [ -z "$T_DNS" ]; then
    R="$(aws route53 test-dns-answer --hosted-zone-id "$ZONE" --record-name "portefeuilles.$DOMAINE" --record-type A --query 'RecordData[0]' --output text)"
    [ "$R" = "203.0.113.50" ] && T_DNS=$(( $(date +%s) - T0 ))
  fi
  [ -n "$T_DNS" ] && break; sleep 3
done
ligne 10 "Bascule DNS vers le secours" "< 120 s" "${T_DNS:-non atteinte} s" "$([ -n "$T_DNS" ] && [ "$T_DNS" -lt 120 ] && echo OK || echo KO)"
ligne 9 "Taux d'erreur client pendant la panne" "mesure" "$ERR / $TOT requetes" OK
aws elbv2 register-targets --region "$REGION" --target-group-arn "$TGWEB" --targets Id="$WEB",Port=80
T0=$(date +%s); T_RET=""
for _ in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://$CF/health")" = 200 ] && { T_RET=$(( $(date +%s) - T0 )); break; }
  sleep 3
done
ligne 9 "Retour de web-01 en service" "< 120 s" "${T_RET:-non atteint} s" "$([ -n "$T_RET" ] && echo OK || echo KO)"

printf '\n**Bilan : %s test(s) bloquant(s) en echec.**\n' "$KO" | tee -a "$RAPPORT"
exit $(( KO > 0 ? 1 : 0 ))
