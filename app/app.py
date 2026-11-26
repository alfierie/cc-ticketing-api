"""ticket-api: Flask REST API for help-desk tickets (Track B: EC2 + Docker + ECR)."""
import uuid
from datetime import datetime, timezone

from flask import Flask, jsonify, request
from werkzeug.exceptions import HTTPException

VALID_STATUS = {"OPEN", "IN_PROGRESS", "RESOLVED", "CLOSED"}
VALID_PRIORITY = {"LOW", "MEDIUM", "HIGH"}
WRITABLE_FIELDS = {"title", "description", "status", "priority", "requesterName"}
TEXT_LIMITS = {"title": 200, "description": 5000, "requesterName": 100}


class ValidationError(Exception):
    pass


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _json_body():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        raise ValidationError("Request body must be a JSON object")
    return data


def _validate(data, partial):
    unknown = set(data) - WRITABLE_FIELDS
    if unknown:
        raise ValidationError("Unknown field(s): " + ", ".join(sorted(unknown)))
    for field, limit in TEXT_LIMITS.items():
        if field in data:
            if not isinstance(data[field], str):
                raise ValidationError(f"'{field}' must be a string")
            if len(data[field]) > limit:
                raise ValidationError(f"'{field}' must be at most {limit} characters")
    for field in ("title", "requesterName"):
        if (not partial or field in data) and not data.get(field, "").strip():
            raise ValidationError(f"'{field}' is required and cannot be empty")
    if "status" in data and data["status"] not in VALID_STATUS:
        raise ValidationError("'status' must be one of " + ", ".join(sorted(VALID_STATUS)))
    if "priority" in data and data["priority"] not in VALID_PRIORITY:
        raise ValidationError("'priority' must be one of " + ", ".join(sorted(VALID_PRIORITY)))


def create_app(repo=None):
    app = Flask(__name__)
    app.json.sort_keys = False
    if repo is None:
        from repository import MySQLRepository

        repo = MySQLRepository.from_env()

    def not_found(ticket_id):
        return jsonify(message=f"Ticket {ticket_id} not found"), 404

    @app.get("/health")
    def health():
        try:
            repo.ping()
            return jsonify(status="ok", database="up")
        except Exception as err:
            app.logger.error("Health check failed: %r", err)
            return jsonify(status="degraded", database="down"), 503

    @app.post("/tickets")
    def create_ticket():
        data = _json_body()
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
        return jsonify(repo.create(ticket)), 201

    @app.get("/tickets")
    def list_tickets():
        items = repo.list()
        return jsonify(count=len(items), items=items)

    @app.get("/tickets/<ticket_id>")
    def get_ticket(ticket_id):
        ticket = repo.get(ticket_id)
        return jsonify(ticket) if ticket else not_found(ticket_id)

    @app.put("/tickets/<ticket_id>")
    def update_ticket(ticket_id):
        data = _json_body()
        if not data:
            raise ValidationError("Provide at least one field to update")
        _validate(data, partial=True)
        for field in ("title", "requesterName"):
            if field in data:
                data[field] = data[field].strip()
        data["updatedAt"] = _now()
        ticket = repo.update(ticket_id, data)
        return jsonify(ticket) if ticket else not_found(ticket_id)

    @app.delete("/tickets/<ticket_id>")
    def delete_ticket(ticket_id):
        return ("", 204) if repo.delete(ticket_id) else not_found(ticket_id)

    @app.errorhandler(ValidationError)
    def bad_request(err):
        return jsonify(message=str(err)), 400

    @app.errorhandler(404)
    def route_not_found(err):
        return jsonify(message="Route not found"), 404

    @app.errorhandler(405)
    def method_not_allowed(err):
        return jsonify(message="Method not allowed"), 405

    @app.errorhandler(Exception)
    def internal_error(err):
        if isinstance(err, HTTPException):
            return jsonify(message=err.description), err.code
        app.logger.exception("Unhandled error")
        return jsonify(message="Internal server error"), 500

    return app
