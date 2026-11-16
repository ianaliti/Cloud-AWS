#!/usr/bin/env bash
# teardown.sh — Delete all resources created by setup.sh
# Useful for a clean re-run without restarting LocalEmu.

set -euo pipefail

# Activate LocalEmu venv so awsemu is on PATH
source ~/localemu-env/bin/activate

REGION="us-east-1"
QUEUE_NAME="tp-orders-queue"
TABLE_NAME="tp-orders"
LAMBDA_A_NAME="lambda-http-receiver"
LAMBDA_B_NAME="lambda-sqs-processor"
API_NAME="tp-orders-api"

warn() { echo "[teardown] $*"; }

warn "Deleting Event Source Mapping..."
ESM_UUID=$(awsemu lambda list-event-source-mappings \
  --function-name "$LAMBDA_B_NAME" --region "$REGION" \
  --query 'EventSourceMappings[0].UUID' --output text 2>/dev/null || true)
[ -n "$ESM_UUID" ] && [ "$ESM_UUID" != "None" ] && \
  awsemu lambda delete-event-source-mapping --uuid "$ESM_UUID" --region "$REGION" 2>/dev/null || true

warn "Deleting Lambda functions..."
awsemu lambda delete-function --function-name "$LAMBDA_A_NAME" --region "$REGION" 2>/dev/null || true
awsemu lambda delete-function --function-name "$LAMBDA_B_NAME" --region "$REGION" 2>/dev/null || true

warn "Deleting SQS queue..."
QUEUE_URL=$(awsemu sqs get-queue-url --queue-name "$QUEUE_NAME" --region "$REGION" --query 'QueueUrl' --output text 2>/dev/null || true)
[ -n "$QUEUE_URL" ] && awsemu sqs delete-queue --queue-url "$QUEUE_URL" --region "$REGION" 2>/dev/null || true

warn "Deleting DynamoDB table..."
awsemu dynamodb delete-table --table-name "$TABLE_NAME" --region "$REGION" 2>/dev/null || true

warn "Deleting API Gateway..."
API_ID=$(awsemu apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text 2>/dev/null || true)
[ -n "$API_ID" ] && [ "$API_ID" != "None" ] && \
  awsemu apigatewayv2 delete-api --api-id "$API_ID" --region "$REGION" 2>/dev/null || true

warn "Deleting Lambda Function URL..."
awsemu lambda delete-function-url-config --function-name "$LAMBDA_A_NAME" --region "$REGION" 2>/dev/null || true

rm -f "$(dirname "$0")/.env.local"

warn "Done. Run setup.sh to recreate everything."
