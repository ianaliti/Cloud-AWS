#!/usr/bin/env bash
source ~/localemu-env/bin/activate

STREAM=$(awsemu logs describe-log-streams \
  --log-group-name /aws/lambda/lambda-sqs-processor \
  --region us-east-1 \
  --order-by LastEventTime \
  --descending \
  --query 'logStreams[0].logStreamName' \
  --output text)

echo "Stream: $STREAM"
echo "---"

awsemu logs get-log-events \
  --log-group-name /aws/lambda/lambda-sqs-processor \
  --log-stream-name "$STREAM" \
  --region us-east-1 \
  --query 'events[*].message' \
  --output text
