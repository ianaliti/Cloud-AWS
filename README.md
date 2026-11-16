# TP AWS Lambda – Architecture Serverless 100 % Locale

Implémentation complète du pipeline **HTTP → Lambda → SQS → Lambda → DynamoDB** à l'aide de **LocalEmu** (émulateur local AWS). Aucun compte AWS, aucune carte bancaire.

---

## Architecture

```
Client HTTP
     │
     ▼
API Gateway (HTTP API v2)
     │  POST /orders
     ▼
Lambda A  (lambda-http-receiver)
  • Valide le payload
  • Publie dans SQS
  • Retourne 202 Accepted
     │
     ▼
Amazon SQS  (tp-orders-queue)
  • File FIFO asynchrone
  • Découple Lambda A de Lambda B
     │  Event Source Mapping (polling automatique)
     ▼
Lambda B  (lambda-sqs-processor)
  • Désérialise le message
  • Écrit dans DynamoDB (idempotent)
     │
     ▼
Amazon DynamoDB  (tp-orders)
  • Table clé de partition : id (UUID)
```

### Rôle de chaque composant

| Composant | Rôle |
|-----------|------|
| **API Gateway** | Expose l'URL HTTP, transmet la requête à Lambda A via l'intégration Lambda Proxy |
| **Lambda A** | Reçoit le JSON, publie un message SQS, répond immédiatement 202 |
| **SQS** | Stocke le message durablement ; Lambda B lit à son propre rythme |
| **Lambda B** | Déclenché automatiquement par l'Event Source Mapping ; écrit en DynamoDB |
| **DynamoDB** | Persistance finale des données ; table NoSQL clé-valeur |

---

## Prérequis

| Outil | Version testée |
|-------|---------------|
| Python | ≥ 3.10 |
| Docker Desktop | ≥ 4.x (daemon lancé) |
| Git | ≥ 2.x |
| LocalEmu | installé via pip (voir ci-dessous) |

---

## Démarrage local

### 1. Installer LocalEmu (une seule fois)

```bash
python3 -m venv ~/localemu-env
source ~/localemu-env/bin/activate
pip install --upgrade pip
pip install "localemu[runtime]"
```

### 2. Démarrer LocalEmu (terminal 1 — laisser ouvert)

```bash
source ~/localemu-env/bin/activate
localemu start
```

Vérifier dans un second terminal :

```bash
source ~/localemu-env/bin/activate
localemu status
awsemu sts get-caller-identity   # doit retourner Account: 000000000000
```

> **Preuve que l'on cible l'émulateur et non AWS :**  
> `awsemu` injecte automatiquement `--endpoint-url http://localhost:4566`.  
> L'`Account` retourné est toujours `000000000000`, jamais un compte AWS réel.

### 3. Construire les packages Lambda

```bash
cd infra
./build.sh
```

Cela installe les dépendances et crée `lambda_a/function.zip` et `lambda_b/function.zip`.

### 4. Déployer toutes les ressources

```bash
./setup.sh
```

Le script crée dans LocalEmu : la file SQS, la table DynamoDB, les deux Lambda, l'Event Source Mapping, l'API Gateway. Il affiche l'URL de l'endpoint à la fin.

### 5. Tester le pipeline complet

```bash
./test.sh
```

Ou manuellement :

```bash
# Remplacer <API_ID> par la valeur affichée par setup.sh
curl -s -X POST http://localhost:4566/_aws/execute-api/<API_ID>/$default/orders \
     -H "Content-Type: application/json" \
     -d '{"name":"Alice","quantity":3}' | python3 -m json.tool
```

Réponse attendue (202) :

```json
{
  "message": "Accepted",
  "id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "sqs_message_id": "yyyyyyyy-...",
  "note": "Processing is asynchronous. Check DynamoDB after a moment."
}
```

Vérifier la persistance après quelques secondes :

```bash
awsemu dynamodb scan --table-name tp-orders --region us-east-1 --output json
```

---

## Tests et scénarios

| Scénario | Commande | Résultat attendu |
|----------|----------|-----------------|
| Payload valide | `{"name":"Alice","quantity":3}` | 202 + id dans la réponse |
| Plusieurs appels | 3 POSTs successifs | 3 entrées distinctes dans DynamoDB |
| Payload invalide | `{"quantity":5}` (sans `name`) | 400 + message d'erreur |
| Vérification async | Lire DynamoDB **immédiatement** après le POST | L'enregistrement peut ne pas encore y être |

---

## Questions d'analyse

**Pourquoi ne pas écrire directement dans DynamoDB depuis Lambda A ?**  
Lambda A est sur le chemin critique de la réponse HTTP : chaque milliseconde compte. Si DynamoDB est lent ou indisponible, l'appel HTTP échouerait. En passant par SQS, Lambda A délègue et répond immédiatement ; Lambda B peut réessayer en cas d'échec sans impacter l'utilisateur.

**Quel est l'intérêt de SQS ?**  
SQS découple producteur et consommateur en termes de débit, de disponibilité et de cycle de vie. Si Lambda B plante, le message reste dans la file (jusqu'au délai de rétention, 4 jours par défaut) et est retraité automatiquement. Sans SQS, un crash de Lambda B signifierait une perte de données.

**Que se passe-t-il si un message est traité plusieurs fois ?**  
SQS garantit une livraison *at-least-once* (au moins une fois), pas *exactly-once*. Lambda B utilise une `ConditionExpression` (`attribute_not_exists(id)`) pour ignorer silencieusement les doublons — c'est le mécanisme d'idempotence.

**Différences avec Azure (TP 1) ?**

| Azure | AWS équivalent |
|-------|---------------|
| Azure Functions | AWS Lambda |
| Azure Queue Storage | Amazon SQS |
| Azure Table Storage | Amazon DynamoDB |
| Azure API Management / HTTP Trigger | Amazon API Gateway |
| Azurite | LocalEmu |

Les concepts sont quasi-identiques ; la terminologie et les SDKs diffèrent (Azure SDK vs boto3).

---

## Structure du projet

```
tp-aws-lambda/
├── lambda_a/
│   ├── handler.py          # Lambda A — réception HTTP
│   └── requirements.txt
├── lambda_b/
│   ├── handler.py          # Lambda B — consommateur SQS
│   └── requirements.txt
├── infra/
│   ├── build.sh            # Crée les ZIPs de déploiement
│   ├── setup.sh            # Provisionne toutes les ressources dans LocalEmu
│   ├── teardown.sh         # Supprime toutes les ressources
│   └── test.sh             # Scénarios de validation bout-en-bout
├── .gitignore
└── README.md
```

---

## Limites identifiées

- **Persistance LocalEmu** : par défaut, les ressources disparaissent à l'arrêt. Relancer `setup.sh` après chaque démarrage de LocalEmu.
- **Python 3.14 / LocalEmu** : LocalEmu exige Python ≥ 3.10 ; les versions très récentes (3.14+) peuvent présenter des incompatibilités mineures.
- **Event Source Mapping local** : le polling SQS→Lambda B peut avoir un délai de quelques secondes dans LocalEmu — normal, pas un bug.
- **API Gateway v2 local** : l'URL locale diffère du format AWS réel (`/_aws/execute-api/…` vs `https://<id>.execute-api.<region>.amazonaws.com`).
- **IAM simulé** : LocalEmu n'applique pas les politiques IAM réelles ; en production, des rôles et politiques stricts seraient nécessaires.
