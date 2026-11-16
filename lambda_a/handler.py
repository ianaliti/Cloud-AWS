import json
import os
import uuid
import logging
import boto3
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sqs = boto3.client("sqs")
QUEUE_URL = os.environ["SQS_QUEUE_URL"]


def lambda_handler(event, context):
    logger.info("Lambda A invoked. RequestId: %s", context.aws_request_id)
    logger.info("Event: %s", json.dumps(event))

    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid JSON body"})

    name = body.get("name", "").strip()
    if not name:
        return _response(400, {"error": "Field 'name' is required"})

    message = {
        "id": str(uuid.uuid4()),
        "name": name,
        "data": body,
        "received_at": datetime.now(timezone.utc).isoformat(),
        "source_request_id": context.aws_request_id,
    }

    try:
        sqs_response = sqs.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps(message),
            MessageAttributes={
                "source": {"StringValue": "lambda-a-http", "DataType": "String"}
            },
        )
        logger.info("Message sent to SQS. MessageId: %s", sqs_response["MessageId"])
    except Exception as exc:
        logger.error("Failed to send message to SQS: %s", exc, exc_info=True)
        return _response(500, {"error": "Could not queue message"})

    # 202 (not 200): request accepted but processing is async — data not yet in DynamoDB
    return _response(
        202,
        {
            "message": "Accepted",
            "id": message["id"],
            "sqs_message_id": sqs_response["MessageId"],
            "note": "Processing is asynchronous. Check DynamoDB after a moment.",
        },
    )


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
