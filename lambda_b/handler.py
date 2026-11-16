import json
import os
import logging
import boto3
from datetime import datetime, timezone
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
TABLE_NAME = os.environ["DYNAMODB_TABLE"]
table = dynamodb.Table(TABLE_NAME)


def lambda_handler(event, context):
    logger.info(
        "Lambda B invoked. %d record(s). RequestId: %s",
        len(event.get("Records", [])),
        context.aws_request_id,
    )

    failures = []
    for record in event.get("Records", []):
        message_id = record["messageId"]
        try:
            _process_record(record)
        except Exception as exc:
            logger.error("Failed to process record %s: %s", message_id, exc, exc_info=True)
            # Report partial failure so SQS retains this message for retry
            failures.append({"itemIdentifier": message_id})

    if failures:
        logger.warning("%d record(s) failed and will be retried.", len(failures))
        return {"batchItemFailures": failures}

    logger.info("All records processed successfully.")
    return {}


def _process_record(record: dict):
    raw_body = record.get("body", "")

    try:
        message = json.loads(raw_body)
    except json.JSONDecodeError as exc:
        # Malformed JSON can never succeed on retry — discard silently
        logger.error("Malformed JSON in SQS message body: %s", exc)
        return

    item_id = message.get("id")
    name = message.get("name")
    if not item_id or not name:
        logger.error("Missing required fields. Keys present: %s", list(message.keys()))
        return

    item = {
        "id": item_id,
        "name": name,
        "data": json.dumps(message.get("data", {})),
        "received_at": message.get("received_at", ""),
        "processed_at": datetime.now(timezone.utc).isoformat(),
        "source_request_id": message.get("source_request_id", ""),
        "sqs_message_id": record["messageId"],
    }

    try:
        table.put_item(
            Item=item,
            # Idempotency guard: SQS delivers at-least-once, ignore duplicates
            ConditionExpression="attribute_not_exists(id)",
        )
        logger.info("Item written to DynamoDB. id=%s name=%s", item_id, name)
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            logger.warning("Duplicate message ignored. id=%s", item_id)
        else:
            raise
