#!/usr/bin/env bash
# Publie le depot sur GitHub avec une pull request par sprint (Git Bash, macOS ou Linux ; gh authentifie).
#   Usage : bash scripts/publier-sprints.sh <compte-github>
# 1. Commit initial sur main : pipeline, politiques, scripts, tests, parametres, amorce IAM, socle.
# 2. Protection de main (PR + controles lint/securite obligatoires) et environnement prod avec relecteur.
# 3. Une branche + une PR par sprint ; fusion seulement si la pipeline (lint + securite) est verte.
set -euo pipefail
COMPTE="${1:?Usage: $0 <compte-github>}"
DEPOT="satom-leman-portail"
cd "$(dirname "$0")/.."

git init -q -b main 2>/dev/null || true
git add README.md .gitignore .checkov.yaml .github policies scripts tests parameters bootstrap templates/00-socle.yaml
git commit -q -m "Amorce : pipeline DevSecOps, politiques, scripts, tests, parametres, socle"
gh repo create "$COMPTE/$DEPOT" --public --source . --remote origin --push

ID_UTILISATEUR="$(gh api "users/$COMPTE" --jq .id)"
gh api -X PUT "repos/$COMPTE/$DEPOT/environments/dev" >/dev/null
gh api -X PUT "repos/$COMPTE/$DEPOT/environments/prod" --input - >/dev/null <<EOF
{"reviewers":[{"type":"User","id":$ID_UTILISATEUR}],"prevent_self_review":false}
EOF
gh api -X PUT "repos/$COMPTE/$DEPOT/branches/main/protection" --input - >/dev/null <<'EOF'
{
  "required_status_checks": {"strict": true, "contexts": ["1 - Lint (cfn-lint, shellcheck)", "2 - Securite statique (cfn-guard, checkov, gitleaks)"]},
  "enforce_admins": false,
  "required_pull_request_reviews": {"required_approving_review_count": 0},
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
echo "main protegee : plus aucun commit direct."

pr() { # pr <branche> <titre> <fichiers...>
  local branche="$1" titre="$2"; shift 2
  git switch -q main && git pull -q origin main
  git switch -q -c "$branche"
  git add "$@"
  git commit -q -m "$titre"
  git push -q -u origin "$branche"
  gh pr create --base main --head "$branche" --title "$titre" \
    --body "Livrable du sprint : template, controle de securite, mesure. Detail dans docs/journal-de-projet.md."
  sleep 15
  gh pr checks "$branche" --watch --fail-fast
  gh pr review "$branche" --comment --body "Relu : template valide (cfn-lint), politiques cfn-guard respectees, aucun secret (gitleaks)." || true
  gh pr merge "$branche" --squash --delete-branch
}

pr sprint-01-02-reseau        "Sprints 1-2 : VPC, sous-reseaux, IGW, NAT, routage"   templates/01-reseau.yaml
pr sprint-03-securite         "Sprint 3 : Security Groups et NACL"                   templates/02-securite.yaml
pr sprint-04-pare-feu         "Sprint 4 : Network Firewall"                          templates/03-pare-feu.yaml
pr sprint-05-08-interconnexion "Sprints 5-8 : peering, Transit Gateway, VPN, Direct Connect" templates/04-interconnexion.yaml
pr sprint-09-alb              "Sprint 9 : instances et Application Load Balancer"    templates/05-calcul.yaml
pr sprint-10-11-edge-dns      "Sprints 10-11 : Route 53, CloudFront, WAF"            templates/06-edge-dns.yaml templates/06a-waf-us-east-1.yaml
pr sprint-12-supervision      "Sprint 12 : supervision et services de securite"      templates/07-supervision.yaml
pr sprint-13-documentation    "Sprint 13 : journal, architecture, rapport, procedures" docs
echo "Toutes les PR sont fusionnees : https://github.com/$COMPTE/$DEPOT/pulls?q=is%3Apr"
