# TP AWS Lambda 

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
**Différences avec Azure (TP 1) ?**

| Azure | AWS équivalent |
|-------|---------------|
| Azure Functions | AWS Lambda |
| Azure Queue Storage | Amazon SQS |
| Azure Table Storage | Amazon DynamoDB |
| Azure API Management / HTTP Trigger | Amazon API Gateway |
| Azurite | LocalEmu |

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
│   ├── test.sh             # Scénarios de validation bout-en-bout
│   └── logs.sh             # Affiche les logs de Lambda B
├── images/                 # Preuves d'exécution (screenshots)
├── .gitignore
└── README.md
```

---

## Preuves d'exécution

### 1. LocalEmu répond en local — aucun compte AWS utilisé

![get-caller-identity](images/Screenshot%202026-11-16%20at%2013.28.46.png)

On lance `awsemu sts get-caller-identity` et on voit `"Account": "000000000000"`. Ce numéro de compte est faux — c'est LocalEmu qui répond, pas AWS. Ça prouve qu'on ne touche pas à un vrai compte AWS.

---

### 2. Toutes les ressources sont créées dans LocalEmu

![setup.sh](images/Screenshot%202026-11-16%20at%2013.32.57.png)

Le script `setup.sh` crée la file SQS, la table DynamoDB, les deux fonctions Lambda, l'API Gateway et l'URL HTTP. À la fin il affiche l'adresse pour envoyer des requêtes.

---

### 3. Les 4 scénarios de test passent

![test.sh](images/Screenshot%202026-11-16%20at%2013.34.54.png)

On voit les 4 tests :
- Un payload valide → Lambda A répond avec un `id`
- Lecture immédiate de DynamoDB → le record n'est pas encore là (preuve que le traitement est asynchrone)
- 3 appels avec des données différentes → 3 messages envoyés dans SQS
- Un payload sans le champ `name` → Lambda A retourne une erreur 400

À la fin, DynamoDB contient bien 4 enregistrements.

---

### 4. Lambda B est déclenchée automatiquement par SQS

![logs Lambda B](images/Screenshot%202026-11-16%20at%2013.39.05.png)

Les logs de Lambda B montrent qu'elle a été appelée 4 fois automatiquement, une fois par message dans la file SQS. À chaque fois elle écrit dans DynamoDB. Lambda B n'a pas été appelée manuellement — c'est l'Event Source Mapping qui fait le déclenchement.

---

### 5. Les données sont bien enregistrées dans DynamoDB

![dynamodb scan](images/Screenshot%202026-11-16%20at%2013.39.47.png)

On voit les enregistrements dans DynamoDB : Alice, Order-1, Order-2, Order-3. Chaque item a un `id` unique, le `name`, les données d'origine, et deux timestamps — `received_at` (quand Lambda A a reçu la requête) et `processed_at` (quand Lambda B a écrit dans la base).

---

## Limites identifiées 

- **Persistance LocalEmu** : par défaut, les ressources disparaissent à l'arrêt. Relancer `setup.sh` après chaque démarrage de LocalEmu.
- **Python 3.14 / LocalEmu** : LocalEmu exige Python ≥ 3.10 ; les versions très récentes (3.14+) peuvent présenter des incompatibilités mineures.
- **Event Source Mapping local** : le polling SQS→Lambda B peut avoir un délai de quelques secondes dans LocalEmu — normal, pas un bug.
- **API Gateway v2 local** : l'URL locale diffère du format AWS réel (`/_aws/execute-api/…` vs `https://<id>.execute-api.<region>.amazonaws.com`).
- **IAM simulé** : LocalEmu n'applique pas les politiques IAM réelles ; en production, des rôles et politiques stricts seraient nécessaires.
