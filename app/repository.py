"""Storage layer for tickets.

MySQLRepository talks to the `ticket-db` container (MySQL 8.0).
InMemoryRepository is used by the unit tests so they run without a database.
Both expose the same five methods, so the API code doesn't care which one it gets.
"""
import os
from datetime import datetime, timezone

# API field name -> MySQL column name (also the allow-list for UPDATE)
COLUMNS = {
    "ticketId": "ticket_id",
    "title": "title",
    "description": "description",
    "status": "status",
    "priority": "priority",
    "requesterName": "requester_name",
    "createdAt": "created_at",
    "updatedAt": "updated_at",
}


def _to_db_time(iso_string):
    return datetime.fromisoformat(iso_string).astimezone(timezone.utc).replace(tzinfo=None)


def _from_db_time(value):
    return value.replace(tzinfo=timezone.utc).isoformat(timespec="seconds")


class InMemoryRepository:
    def __init__(self):
        self._items = {}

    def ping(self):
        return True

    def create(self, ticket):
        self._items[ticket["ticketId"]] = dict(ticket)
        return dict(ticket)

    def list(self):
        return sorted((dict(t) for t in self._items.values()), key=lambda t: t["createdAt"], reverse=True)

    def get(self, ticket_id):
        item = self._items.get(ticket_id)
        return dict(item) if item else None

    def update(self, ticket_id, fields):
        if ticket_id not in self._items:
            return None
        self._items[ticket_id].update(fields)
        return dict(self._items[ticket_id])

    def delete(self, ticket_id):
        return self._items.pop(ticket_id, None) is not None


class MySQLRepository:
    def __init__(self, host, user, password, database, port=3306):
        self._config = dict(host=host, user=user, password=password, database=database, port=port)

    @classmethod
    def from_env(cls):
        return cls(
            host=os.environ.get("DB_HOST", "db"),
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASSWORD"],
            database=os.environ.get("DB_NAME", "ticketing"),
            port=int(os.environ.get("DB_PORT", "3306")),
        )

    def _connect(self):
        import pymysql

        return pymysql.connect(
            **self._config,
            cursorclass=pymysql.cursors.DictCursor,
            autocommit=True,
            connect_timeout=5,
            # make UPDATE report matched rows, not just changed rows
            client_flag=pymysql.constants.CLIENT.FOUND_ROWS,
        )

    @staticmethod
    def _row_to_ticket(row):
        ticket = {api: row[col] for api, col in COLUMNS.items()}
        ticket["createdAt"] = _from_db_time(ticket["createdAt"])
        ticket["updatedAt"] = _from_db_time(ticket["updatedAt"])
        return ticket

    def ping(self):
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
        return True

    def create(self, ticket):
        values = dict(ticket)
        values["createdAt"] = _to_db_time(values["createdAt"])
        values["updatedAt"] = _to_db_time(values["updatedAt"])
        cols = ", ".join(COLUMNS.values())
        params = ", ".join(f"%({api})s" for api in COLUMNS)
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute(f"INSERT INTO tickets ({cols}) VALUES ({params})", values)
        return dict(ticket)

    def list(self):
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT * FROM tickets ORDER BY created_at DESC")
            return [self._row_to_ticket(r) for r in cur.fetchall()]

    def get(self, ticket_id):
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT * FROM tickets WHERE ticket_id = %s", (ticket_id,))
            row = cur.fetchone()
        return self._row_to_ticket(row) if row else None

    def update(self, ticket_id, fields):
        values = dict(fields)
        if "updatedAt" in values:
            values["updatedAt"] = _to_db_time(values["updatedAt"])
        # column names come from the COLUMNS allow-list, values are parameterized
        assignments = ", ".join(f"{COLUMNS[k]} = %({k})s" for k in values)
        values["_id"] = ticket_id
        with self._connect() as conn, conn.cursor() as cur:
            matched = cur.execute(f"UPDATE tickets SET {assignments} WHERE ticket_id = %(_id)s", values)
        return self.get(ticket_id) if matched else None

    def delete(self, ticket_id):
        with self._connect() as conn, conn.cursor() as cur:
            return cur.execute("DELETE FROM tickets WHERE ticket_id = %s", (ticket_id,)) > 0
