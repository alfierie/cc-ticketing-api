"""
Ticketing API - AWS Lambda handler (Track C: API Gateway + Lambda + DynamoDB).

One Lambda function serves every route of an API Gateway HTTP API
(payload format 2.0). Data is stored in a DynamoDB table whose
partition key is `ticketId` (string).
"""
import base64
import json
import os
import uuid
from datetime import datetime, timezone

TABLE_NAME = os.environ.get("TABLE_NAME", "Tickets")

VALID_STATUS = {"OPEN", "IN_PROGRESS", "RESOLVED", "CLOSED"}
VALID_PRIORITY = {"LOW", "MEDIUM", "HIGH"}
WRITABLE_FIELDS = {"title", "description", "status", "priority", "requesterName"}
TEXT_FIELDS = {"title", "description", "requesterName"}

_table = None


def get_table():
    """Lazily create the DynamoDB Table resource (lets tests inject a fake)."""
    global _table
    if _table is None:
        import boto3  # bundled in the Lambda Python runtime

        _table = boto3.resource("dynamodb").Table(TABLE_NAME)
    return _table


class BadRequest(Exception):
    pass


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _response(status, body=None):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": "" if body is None else json.dumps(body),
    }


def _is_condition_failure(err):
    code = getattr(err, "response", {}).get("Error", {}).get("Code")
    return code == "ConditionalCheckFailedException"


def _parse_body(event):
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    if not raw.strip():
        raise BadRequest("Request body is required")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        raise BadRequest("Request body must be valid JSON")
    if not isinstance(data, dict):
        raise BadRequest("Request body must be a JSON object")
    return data


def _validate(data, partial):
    unknown = set(data) - WRITABLE_FIELDS
    if unknown:
        raise BadRequest("Unknown field(s): " + ", ".join(sorted(unknown)))
    for field in TEXT_FIELDS & set(data):
        if not isinstance(data[field], str):
            raise BadRequest(f"'{field}' must be a string")
    if not partial:
        for field in ("title", "requesterName"):
            if not data.get(field, "").strip():
                raise BadRequest(f"'{field}' is required")
    else:
        for field in ("title", "requesterName"):
            if field in data and not data[field].strip():
                raise BadRequest(f"'{field}' cannot be empty")
    if "status" in data and data["status"] not in VALID_STATUS:
        raise BadRequest("'status' must be one of " + ", ".join(sorted(VALID_STATUS)))
    if "priority" in data and data["priority"] not in VALID_PRIORITY:
        raise BadRequest("'priority' must be one of " + ", ".join(sorted(VALID_PRIORITY)))


# ---------- CRUD operations ----------

def create_ticket(event):
    data = _parse_body(event)
    _validate(data, partial=False)
    now = _now()
    ticket = {
        "ticketId": str(uuid.uuid4()),
        "title": data["title"].strip(),
        "description": data.get("description", ""),
        "status": data.get("status", "OPEN"),
        "priority": data.get("priority", "MEDIUM"),
        "requesterName": data["requesterName"].strip(),
        "createdAt": now,
        "updatedAt": now,
    }
    get_table().put_item(Item=ticket, ConditionExpression="attribute_not_exists(ticketId)")
    return _response(201, ticket)


def list_tickets(event):
    table = get_table()
    items, kwargs = [], {}
    while True:
        page = table.scan(**kwargs)
        items.extend(page.get("Items", []))
        if "LastEvaluatedKey" not in page:
            break
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]
    items.sort(key=lambda t: t.get("createdAt", ""), reverse=True)
    return _response(200, {"count": len(items), "items": items})


def get_ticket(event, ticket_id):
    item = get_table().get_item(Key={"ticketId": ticket_id}).get("Item")
    if not item:
        return _response(404, {"message": f"Ticket {ticket_id} not found"})
    return _response(200, item)


def update_ticket(event, ticket_id):
    data = _parse_body(event)
    if not data:
        raise BadRequest("Provide at least one field to update")
    _validate(data, partial=True)
    data["updatedAt"] = _now()
    names = {f"#{k}": k for k in data}
    values = {f":{k}": v for k, v in data.items()}
    expr = "SET " + ", ".join(f"#{k} = :{k}" for k in data)
    try:
        result = get_table().update_item(
            Key={"ticketId": ticket_id},
            UpdateExpression=expr,
            ExpressionAttributeNames=names,
            ExpressionAttributeValues=values,
            ConditionExpression="attribute_exists(ticketId)",
            ReturnValues="ALL_NEW",
        )
    except Exception as err:
        if _is_condition_failure(err):
            return _response(404, {"message": f"Ticket {ticket_id} not found"})
        raise
    return _response(200, result["Attributes"])


def delete_ticket(event, ticket_id):
    try:
        get_table().delete_item(
            Key={"ticketId": ticket_id},
            ConditionExpression="attribute_exists(ticketId)",
        )
    except Exception as err:
        if _is_condition_failure(err):
            return _response(404, {"message": f"Ticket {ticket_id} not found"})
        raise
    return _response(204)


ROUTES = {
    "POST /tickets": lambda e: create_ticket(e),
    "GET /tickets": lambda e: list_tickets(e),
    "GET /tickets/{id}": lambda e: get_ticket(e, e["pathParameters"]["id"]),
    "PUT /tickets/{id}": lambda e: update_ticket(e, e["pathParameters"]["id"]),
    "DELETE /tickets/{id}": lambda e: delete_ticket(e, e["pathParameters"]["id"]),
}


def lambda_handler(event, context):
    route = event.get("routeKey", "")
    handler = ROUTES.get(route)
    if handler is None:
        return _response(404, {"message": f"Route '{route}' not found"})
    try:
        return handler(event)
    except BadRequest as err:
        return _response(400, {"message": str(err)})
    except Exception as err:  # logged to CloudWatch Logs
        print(f"ERROR on {route}: {err!r}")
        return _response(500, {"message": "Internal server error"})
