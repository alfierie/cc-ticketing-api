"""Unit tests for ticket-api using Flask's test client and the in-memory repository.

Run from the repo root:
    pip install -r app/requirements.txt
    python3 -m unittest discover -s tests -v
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))
from app import create_app  # noqa: E402
from repository import InMemoryRepository  # noqa: E402


class TicketApiTests(unittest.TestCase):
    def setUp(self):
        self.client = create_app(repo=InMemoryRepository()).test_client()

    def _create(self, **overrides):
        payload = {"title": "Projector not working", "requesterName": "Diffie", **overrides}
        return self.client.post("/tickets", json=payload)

    def test_health(self):
        resp = self.client.get("/health")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.get_json()["database"], "up")

    def test_create_sets_defaults(self):
        resp = self._create()
        self.assertEqual(resp.status_code, 201)
        body = resp.get_json()
        self.assertEqual(body["status"], "OPEN")
        self.assertEqual(body["priority"], "MEDIUM")
        self.assertIn("ticketId", body)

    def test_create_requires_title(self):
        resp = self.client.post("/tickets", json={"requesterName": "Diffie"})
        self.assertEqual(resp.status_code, 400)
        self.assertIn("title", resp.get_json()["message"])

    def test_create_rejects_bad_priority_and_invalid_json(self):
        self.assertEqual(self._create(priority="URGENT").status_code, 400)
        resp = self.client.post("/tickets", data="{oops", content_type="application/json")
        self.assertEqual(resp.status_code, 400)

    def test_list_returns_all(self):
        self._create()
        self._create(title="Wi-Fi down in lab")
        body = self.client.get("/tickets").get_json()
        self.assertEqual(body["count"], 2)

    def test_get_existing_and_missing(self):
        ticket_id = self._create().get_json()["ticketId"]
        resp = self.client.get(f"/tickets/{ticket_id}")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.get_json()["title"], "Projector not working")
        self.assertEqual(self.client.get("/tickets/does-not-exist").status_code, 404)

    def test_update_changes_fields(self):
        ticket_id = self._create().get_json()["ticketId"]
        resp = self.client.put(f"/tickets/{ticket_id}", json={"status": "IN_PROGRESS"})
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.get_json()["status"], "IN_PROGRESS")
        self.assertEqual(resp.get_json()["title"], "Projector not working")

    def test_update_rejects_unknown_field_and_missing_ticket(self):
        ticket_id = self._create().get_json()["ticketId"]
        self.assertEqual(self.client.put(f"/tickets/{ticket_id}", json={"ticketId": "x"}).status_code, 400)
        self.assertEqual(self.client.put(f"/tickets/{ticket_id}", json={}).status_code, 400)
        self.assertEqual(self.client.put("/tickets/nope", json={"status": "CLOSED"}).status_code, 404)

    def test_delete(self):
        ticket_id = self._create().get_json()["ticketId"]
        self.assertEqual(self.client.delete(f"/tickets/{ticket_id}").status_code, 204)
        self.assertEqual(self.client.delete(f"/tickets/{ticket_id}").status_code, 404)

    def test_unknown_route_and_method(self):
        self.assertEqual(self.client.get("/nope").status_code, 404)
        self.assertEqual(self.client.patch("/tickets").status_code, 405)


class FailingRepository(InMemoryRepository):
    def ping(self):
        raise ConnectionError("db down")


class HealthDegradedTest(unittest.TestCase):
    def test_health_reports_db_down(self):
        client = create_app(repo=FailingRepository()).test_client()
        resp = client.get("/health")
        self.assertEqual(resp.status_code, 503)
        self.assertEqual(resp.get_json()["database"], "down")


if __name__ == "__main__":
    unittest.main()
