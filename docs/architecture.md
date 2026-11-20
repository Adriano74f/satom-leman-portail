# Architecture du portail Léman (IaC)

## Vue d'ensemble

```mermaid
flowchart LR
  subgraph BAN["GIT – Satom · TP final – Portail Léman en IaC (eu-north-1)"]
    direction LR
    CLI(("🌐 Conseillers")):::inet
    WAF["🛡️ AWS WAF<br/>règles gérées + débit"]:::sec
    CF["☁️ CloudFront d-leman-portail<br/>/static/* cache · /api/* sans cache"]:::cf
    R53["Route 53<br/>portefeuilles · failover + health check"]:::dns
    subgraph PROD["vpc-prod-leman · 10.x.0.0/16"]
      direction TB
      subgraph PUB["Publics 1a/1b · 10.x.1.0/24, 10.x.5.0/24"]
        ALB["⚖️ ALB HTTPS 443 (TLS 1.2+)<br/>HTTP 80 = préfixe CloudFront"]:::lb
        WEB["🖥️ web-01 · 10.x.1.10"]:::srv
      end
      subgraph PRIV["Privés 1a/1b · 10.x.2.0/24, 10.x.6.0/24"]
        APP["🖥️ app-01 · 10.x.2.10:8080"]:::srv
      end
      FW["🔥 Network Firewall<br/>sub-fw-1a 10.x.4.0/28"]:::fw
      NAT["NAT · sub-nat-1a 10.x.3.0/24"]:::gw
    end
    subgraph DEV["vpc-dev-leman · 10.y.0.0/16"]
      DEV1["🖥️ dev-01 · 10.y.1.10"]:::srv
    end
    TGW{{"🔀 tgw-leman · ASN 64512<br/>rt-prod / rt-dev / rt-vpn"}}:::tgw
    VPN["🔐 2 VPN IKEv2/BGP<br/>203.0.113.10 · 198.51.100.20"]:::cgw
    DX["dxgw-leman · ASN 64513"]:::cgw
    MON["📊 CloudWatch · SNS · Flow Logs (KMS)<br/>GuardDuty · Security Hub · Config"]:::mon
  end
  CLI --> R53 --> CF
  WAF -.- CF
  CF -- "HTTP 80" --> ALB
  CLI -- "HTTPS 443" --> ALB
  ALB --> WEB
  ALB -- "/api/*" --> APP
  APP -- "0.0.0.0/0" --> FW --> NAT
  APP --- TGW
  DEV1 --- TGW
  TGW --- VPN
  TGW --- DX
  PROD -.-> MON
  classDef inet fill:#fff3e0,stroke:#ef6c00,color:#e65100
  classDef sec fill:#ffebee,stroke:#c62828,color:#b71c1c
  classDef cf fill:#f3e5f5,stroke:#6a1b9a,color:#4a148c
  classDef dns fill:#e0f2f1,stroke:#00796b,color:#004d40
  classDef lb fill:#e3f2fd,stroke:#1565c0,color:#0d47a1
  classDef srv fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20
  classDef fw fill:#ffebee,stroke:#c62828,color:#b71c1c
  classDef gw fill:#eceff1,stroke:#546e7a,color:#263238
  classDef tgw fill:#e3f2fd,stroke:#1565c0,color:#0d47a1
  classDef cgw fill:#fff8e1,stroke:#f9a825,color:#f57f17
  classDef mon fill:#ede7f6,stroke:#4527a0,color:#311b92
  style BAN fill:#ffffff,stroke:#1a237e,stroke-width:3px,color:#1a237e
  style PROD fill:#f5f9ff,stroke:#5c6bc0,stroke-dasharray:6 4
  style DEV fill:#f5f9ff,stroke:#5c6bc0,stroke-dasharray:6 4
  style PUB fill:#f1f8e9,stroke:#2e7d32,stroke-dasharray:4 4
  style PRIV fill:#fffde7,stroke:#f9a825,stroke-dasharray:4 4
```

`x` vaut `20` en dev et `0` en prod ; `y` vaut `21` en dev et `1` en prod (voir [parameters/](../parameters)).

## Plan d'adressage (prod)

| Sous-réseau | CIDR | Zone | Rôle | Table |
|---|---|---|---|---|
| sub-public-1a | 10.0.1.0/24 | a | ALB, web-01 | rt-public → IGW |
| sub-prive-1a | 10.0.2.0/24 | a | app-01, attachement TGW | rt-prive → pare-feu |
| sub-nat-1a | 10.0.3.0/24 | a | NAT Gateway | rt-nat → IGW ; retour privés → pare-feu |
| sub-fw-1a | 10.0.4.0/28 | a | point de terminaison du pare-feu | rt-fw → NAT |
| sub-public-1b | 10.0.5.0/24 | b | ALB | rt-public → IGW |
| sub-prive-1b | 10.0.6.0/24 | b | attachement TGW | rt-prive → pare-feu |
| sub-dev-1a | 10.1.1.0/24 | a | dev-01 (VPC dev) | rt-dev → TGW (ou peering vers 10.0.2.0/24) |

## Chemins

| Flux | Chemin |
|---|---|
| Conseiller → portail | Route 53 → CloudFront (WAF) → ALB:80 (préfixe CloudFront) → web-01 / app-01 |
| app-01 → Internet | rt-prive → Network Firewall (liste de domaines) → NAT → IGW ; retour symétrique par rt-nat |
| dev-01 → app-01:8080 | TGW (`tgw-rt-dev`) ou peering ciblé (`ModeInterDev`) |
| Sites → prod | VPN (BGP) → `tgw-rt-vpn` → attachement prod ; préfixes des sites propagés dans `tgw-rt-prod` |
| Direct Connect | `dxgw-leman` associée à la TGW, préfixe annoncé limité au VPC de prod |

## Ordre des piles et dépendances

`00-socle` → `00b-budget` (us-east-1) → `01-reseau` → `02-securite` → `03-pare-feu` → `04-interconnexion` → `05-calcul` → `06a-waf` (us-east-1) → `06-edge-dns` → `07-supervision`

Les identifiants circulent par `Export` / `Fn::ImportValue` (préfixe `leman-<env>-<equipe>-`). La suppression se fait dans l'ordre inverse ([scripts/supprimer.sh](../scripts/supprimer.sh)).
