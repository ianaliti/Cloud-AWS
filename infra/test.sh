#!/usr/bin/env bash
# test.sh — End-to-end validation of the full pipeline
# Tests: valid payload, multiple calls, invalid payload, async check

set -euo pipefail

source ~/localemu-env/bin/activate

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass()    { echo -e "${GREEN}[PASS]${NC} $*"; }
fail()    { echo -e "${RED}[FAIL]${NC} $*"; }
info()    { echo -e "${YELLOW}[test]${NC} $*"; }

REGION="us-east-1"
TABLE_NAME="tp-orders"

# Load endpoint from setup output
ENV_FILE="$(dirname "$0")/.env.local"
if [ -f "$ENV_FILE" ]; then
  source "$ENV_FILE"
else
  FUNCTION_URL=$(awsemu lambda get-function-url-config \
    --function-name lambda-http-receiver \
    --region "$REGION" \
    --query 'FunctionUrl' --output text 2>/dev/null)
  FUNCTION_URL="${FUNCTION_URL%/}"
fi

ENDPOINT="${FUNCTION_URL}"
info "Endpoint: $ENDPOINT"

check_dynamo() {
  local id="$1"
  awsemu dynamodb get-item \
    --table-name "$TABLE_NAME" \
    --key "{\"id\":{\"S\":\"$id\"}}" \
    --region "$REGION" \
    --query 'Item' --output json 2>/dev/null
}

# =============================================================================
# Test 1 — Valid payload
# =============================================================================
info "=== Test 1: Valid payload ==="
RESP=$(curl -s --max-time 15 -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{"name":"Alice","quantity":3}')

echo "Response: $RESP"
ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")

if echo "$RESP" | grep -q '"id"'; then
  pass "Lambda A responded with an id"
else
  fail "Lambda A did not return expected response"
fi

# =============================================================================
# Test 4 — Async check: 202 does NOT mean DynamoDB already has the record
# =============================================================================
info "=== Test 4: Async check — reading DynamoDB immediately after POST ==="
if [ -n "$ID" ]; then
  ITEM=$(check_dynamo "$ID")
  if [ "$ITEM" = "null" ] || [ -z "$ITEM" ]; then
    pass "DynamoDB does NOT yet have the record — confirms async processing"
  else
    info "DynamoDB already has the record (Lambda B was very fast — this can happen)"
  fi
fi

# =============================================================================
# Test 2 — Multiple calls with distinct data
# =============================================================================
info "=== Test 2: Multiple distinct calls ==="
IDS=()
for i in 1 2 3; do
  R=$(curl -s --max-time 15 -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"Order-${i}\",\"item\":\"product-${i}\",\"qty\":${i}}")
  echo "Call $i: $R"
  IDS+=("$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")")
done
pass "Sent 3 distinct orders. IDs: ${IDS[*]}"

# =============================================================================
# Test 3 — Invalid payload (missing 'name')
# =============================================================================
info "=== Test 3: Invalid payload (missing 'name') ==="
BAD_RESP=$(curl -s --max-time 15 -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{"quantity":5}')
echo "Response: $BAD_RESP"
if echo "$BAD_RESP" | grep -qi "required\|error\|400"; then
  pass "Lambda A correctly rejected the invalid payload"
else
  fail "Lambda A should have returned an error for missing 'name'"
fi

# =============================================================================
# Wait for Lambda B to process all messages (poll up to 20s)
# =============================================================================
info "=== Waiting for Lambda B to process all messages (up to 20s)... ==="
SCAN=0
for i in $(seq 1 10); do
  sleep 2
  SCAN=$(awsemu dynamodb scan --table-name "$TABLE_NAME" --region "$REGION" \
    --query 'Count' --output text)
  info "DynamoDB item count: $SCAN (attempt $i/10)"
  [ "$SCAN" -ge 4 ] && break
done

if [ "$SCAN" -ge 4 ]; then
  pass "DynamoDB contains $SCAN record(s) — full pipeline validated"
else
  fail "Only $SCAN record(s) found after 20s. Check Lambda B logs."
fi

# =============================================================================
# Show all records
# =============================================================================
info "=== All DynamoDB records ==="
awsemu dynamodb scan \
  --table-name "$TABLE_NAME" \
  --region "$REGION" \
  --output json | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('Items', []):
    print(json.dumps({k: list(v.values())[0] for k, v in item.items()}, indent=2))
"
