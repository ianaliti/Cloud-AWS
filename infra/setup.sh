#!/usr/bin/env bash
# setup.sh — Provision all AWS resources inside LocalEmu
# Run after `localemu start`. Idempotent: safe to re-run.

set -euo pipefail

source ~/localemu-env/bin/activate

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[setup]${NC} $*"; }
warning() { echo -e "${YELLOW}[setup]${NC} $*"; }

REGION="us-east-1"
ACCOUNT="000000000000"
QUEUE_NAME="tp-orders-queue"
TABLE_NAME="tp-orders"
LAMBDA_A_NAME="lambda-http-receiver"
LAMBDA_B_NAME="lambda-sqs-processor"
API_NAME="tp-orders-api"

LAMBDA_A_ZIP="../lambda_a/function.zip"
LAMBDA_B_ZIP="../lambda_b/function.zip"

# =============================================================================
# 1. SQS
# =============================================================================
info "Creating SQS queue: $QUEUE_NAME"

QUEUE_URL=$(awsemu sqs create-queue \
  --queue-name "$QUEUE_NAME" \
  --region "$REGION" \
  --query 'QueueUrl' --output text 2>/dev/null || \
  awsemu sqs get-queue-url \
  --queue-name "$QUEUE_NAME" \
  --region "$REGION" \
  --query 'QueueUrl' --output text)

info "Queue URL: $QUEUE_URL"

QUEUE_ARN=$(awsemu sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn \
  --region "$REGION" \
  --query 'Attributes.QueueArn' --output text)

# =============================================================================
# 2. DynamoDB
# =============================================================================
info "Creating DynamoDB table: $TABLE_NAME"

awsemu dynamodb create-table \
  --table-name "$TABLE_NAME" \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region "$REGION" 2>/dev/null || info "Table $TABLE_NAME already exists"

awsemu dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"

# =============================================================================
# 3. IAM Role
# =============================================================================
info "Creating Lambda execution role"

ROLE_NAME="tp-lambda-exec-role"
TRUST_POLICY='{
  "Version":"2012-10-17",
  "Statement":[{
    "Effect":"Allow",
    "Principal":{"Service":"lambda.amazonaws.com"},
    "Action":"sts:AssumeRole"
  }]
}'

awsemu iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document "$TRUST_POLICY" \
  --region "$REGION" 2>/dev/null || info "Role $ROLE_NAME already exists"

ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"

# =============================================================================
# 4. Lambda A
# =============================================================================
info "Deploying Lambda A: $LAMBDA_A_NAME"

awsemu lambda create-function \
  --function-name "$LAMBDA_A_NAME" \
  --runtime python3.12 \
  --role "$ROLE_ARN" \
  --handler "handler.lambda_handler" \
  --zip-file "fileb://$LAMBDA_A_ZIP" \
  --environment "Variables={SQS_QUEUE_URL=${QUEUE_URL}}" \
  --region "$REGION" 2>/dev/null || \
awsemu lambda update-function-code \
  --function-name "$LAMBDA_A_NAME" \
  --zip-file "fileb://$LAMBDA_A_ZIP" \
  --region "$REGION"

awsemu lambda wait function-active --function-name "$LAMBDA_A_NAME" --region "$REGION"

# =============================================================================
# 5. Lambda B
# =============================================================================
info "Deploying Lambda B: $LAMBDA_B_NAME"

awsemu lambda create-function \
  --function-name "$LAMBDA_B_NAME" \
  --runtime python3.12 \
  --role "$ROLE_ARN" \
  --handler "handler.lambda_handler" \
  --zip-file "fileb://$LAMBDA_B_ZIP" \
  --environment "Variables={DYNAMODB_TABLE=${TABLE_NAME}}" \
  --region "$REGION" 2>/dev/null || \
awsemu lambda update-function-code \
  --function-name "$LAMBDA_B_NAME" \
  --zip-file "fileb://$LAMBDA_B_ZIP" \
  --region "$REGION"

awsemu lambda wait function-active --function-name "$LAMBDA_B_NAME" --region "$REGION"

# =============================================================================
# 6. Event Source Mapping (SQS → Lambda B)
# =============================================================================
info "Creating Event Source Mapping: SQS → $LAMBDA_B_NAME"

awsemu lambda create-event-source-mapping \
  --function-name "$LAMBDA_B_NAME" \
  --event-source-arn "$QUEUE_ARN" \
  --batch-size 1 \
  --region "$REGION" 2>/dev/null || info "Event source mapping already exists"

# =============================================================================
# 7. API Gateway HTTP API (architecture documentation — see note below)
# =============================================================================
info "Creating API Gateway HTTP API: $API_NAME"

API_ID=$(awsemu apigatewayv2 create-api \
  --name "$API_NAME" \
  --protocol-type HTTP \
  --region "$REGION" \
  --query 'ApiId' --output text 2>/dev/null || \
  awsemu apigatewayv2 get-apis \
  --region "$REGION" \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text)

LAMBDA_A_ARN="arn:aws:lambda:${REGION}:${ACCOUNT}:function:${LAMBDA_A_NAME}"
INTEGRATION_URI="arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_A_ARN}/invocations"

INTEGRATION_ID=$(awsemu apigatewayv2 create-integration \
  --api-id "$API_ID" \
  --integration-type AWS_PROXY \
  --integration-uri "$INTEGRATION_URI" \
  --payload-format-version "1.0" \
  --region "$REGION" \
  --query 'IntegrationId' --output text)

awsemu apigatewayv2 create-route \
  --api-id "$API_ID" \
  --route-key "POST /orders" \
  --target "integrations/$INTEGRATION_ID" \
  --region "$REGION" > /dev/null

awsemu apigatewayv2 create-stage \
  --api-id "$API_ID" \
  --stage-name "\$default" \
  --auto-deploy \
  --region "$REGION" 2>/dev/null || true

awsemu lambda add-permission \
  --function-name "$LAMBDA_A_NAME" \
  --statement-id "apigw-invoke" \
  --action "lambda:InvokeFunction" \
  --principal "apigateway.amazonaws.com" \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT}:${API_ID}/*" \
  --region "$REGION" 2>/dev/null || true

# =============================================================================
# 8. Lambda Function URL (working HTTP endpoint — API Gateway v2 proxy has a
#    LocalEmu routing bug that returns empty bodies; function URLs work correctly)
# =============================================================================
info "Creating Function URL for Lambda A"

FUNCTION_URL=$(awsemu lambda create-function-url-config \
  --function-name "$LAMBDA_A_NAME" \
  --auth-type NONE \
  --region "$REGION" \
  --query 'FunctionUrl' --output text 2>/dev/null || \
  awsemu lambda get-function-url-config \
  --function-name "$LAMBDA_A_NAME" \
  --region "$REGION" \
  --query 'FunctionUrl' --output text)

# Strip trailing slash
FUNCTION_URL="${FUNCTION_URL%/}"

# Save endpoint for test.sh
echo "FUNCTION_URL=${FUNCTION_URL}" > .env.local
info "Endpoint saved to infra/.env.local"

# =============================================================================
# Summary
# =============================================================================
echo ""
info "============================================================"
info " Setup complete."
info "============================================================"
info " SQS Queue URL   : $QUEUE_URL"
info " DynamoDB Table  : $TABLE_NAME"
info " Lambda A        : $LAMBDA_A_NAME"
info " Lambda B        : $LAMBDA_B_NAME"
info " API Gateway ID  : $API_ID"
info " HTTP Endpoint   : $FUNCTION_URL"
info "------------------------------------------------------------"
info " Test command:"
info "   curl -s -X POST $FUNCTION_URL \\"
info "        -H 'Content-Type: application/json' \\"
info "        -d '{\"name\":\"Alice\",\"quantity\":3}'"
info "============================================================"
