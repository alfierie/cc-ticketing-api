"""Unit tests for the Lambda handler, using an in-memory fake DynamoDB table.

Run from the repo root:  python3 -m unittest discover -s tests -v
"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
import app  # noqa: E402


class ConditionFailed(Exception):
    response = {"Error": {"Code": "ConditionalCheckFailedException"}}


class FakeTable:
    """Implements just the DynamoDB Table methods the handler uses."""

    def __init__(self):
        self.items = {}

    def put_item(self, Item, ConditionExpression=None):
        if Item["ticketId"] in self.items:
            raise ConditionFailed()
        self.items[Item["ticketId"]] = dict(Item)

    def scan(self, **kwargs):
        return {"Items": [dict(i) for i in self.items.values()]}

    def get_item(self, Key):
        item = self.items.get(Key["ticketId"])
        return {"Item": dict(item)} if item else {}

    def update_item(self, Key, ExpressionAttributeNames, ExpressionAttributeValues, **kwargs):
        item = self.items.get(Key["ticketId"])
        if item is None:
            raise ConditionFailed()
        for placeholder, field in ExpressionAttributeNames.items():
            item[field] = ExpressionAttributeValues[":" + placeholder[1:]]
        return {"Attributes": dict(item)}

    def delete_item(self, Key, ConditionExpression=None):
        if Key["ticketId"] not in self.items:
            raise ConditionFailed()
        del self.items[Key["ticketId"]]


def event(route, body=None, ticket_id=None):
    e = {"routeKey": route}
    if body is not None:
        e["body"] = json.dumps(body)
    if ticket_id is not None:
        e["pathParameters"] = {"id": ticket_id}
    return e


def call(*args, **kwargs):
    resp = app.lambda_handler(event(*args, **kwargs), None)
    body = json.loads(resp["body"]) if resp["body"] else None
    return resp["statusCode"], body


class TicketApiTests(unittest.TestCase):
    def setUp(self):
        app._table = FakeTable()

    def _create(self, **overrides):
        payload = {"title": "Projector not working", "requesterName": "Diffie", **overrides}
        return call("POST /tickets", payload)

    def test_create_sets_defaults(self):
        status, body = self._create()
        self.assertEqual(status, 201)
        self.assertEqual(body["status"], "OPEN")
        self.assertEqual(body["priority"], "MEDIUM")
        self.assertIn("ticketId", body)

    def test_create_requires_title(self):
        status, body = call("POST /tickets", {"requesterName": "Diffie"})
        self.assertEqual(status, 400)
        self.assertIn("title", body["message"])

    def test_create_rejects_bad_priority(self):
        status, _ = self._create(priority="URGENT")
        self.assertEqual(status, 400)

    def test_create_rejects_invalid_json(self):
        resp = app.lambda_handler({"routeKey": "POST /tickets", "body": "{oops"}, None)
        self.assertEqual(resp["statusCode"], 400)

    def test_list_returns_all(self):
        self._create()
        self._create(title="Wi-Fi down in lab")
        status, body = call("GET /tickets")
        self.assertEqual(status, 200)
        self.assertEqual(body["count"], 2)

    def test_get_existing_and_missing(self):
        _, created = self._create()
        status, body = call("GET /tickets/{id}", ticket_id=created["ticketId"])
        self.assertEqual(status, 200)
        self.assertEqual(body["title"], "Projector not working")
        status, _ = call("GET /tickets/{id}", ticket_id="does-not-exist")
        self.assertEqual(status, 404)

    def test_update_changes_fields(self):
        _, created = self._create()
        status, body = call("PUT /tickets/{id}", {"status": "IN_PROGRESS"}, ticket_id=created["ticketId"])
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "IN_PROGRESS")
        self.assertEqual(body["title"], "Projector not working")

    def test_update_rejects_unknown_field_and_missing_ticket(self):
        _, created = self._create()
        status, _ = call("PUT /tickets/{id}", {"ticketId": "hack"}, ticket_id=created["ticketId"])
        self.assertEqual(status, 400)
        status, _ = call("PUT /tickets/{id}", {"status": "CLOSED"}, ticket_id="nope")
        self.assertEqual(status, 404)

    def test_delete(self):
        _, created = self._create()
        status, _ = call("DELETE /tickets/{id}", ticket_id=created["ticketId"])
        self.assertEqual(status, 204)
        status, _ = call("DELETE /tickets/{id}", ticket_id=created["ticketId"])
        self.assertEqual(status, 404)

    def test_unknown_route(self):
        status, _ = call("PATCH /tickets")
        self.assertEqual(status, 404)


if __name__ == "__main__":
    unittest.main()
