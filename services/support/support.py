"""XauXat support intake. WSGI behind TLS; operator access is SSH/CLI only."""
from __future__ import annotations

import hashlib
import hmac
import html
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import threading
import time
from urllib.parse import urlsplit
import uuid

CONSENT_VERSION = "2026-10-15"
MAX_BODY = 24576
TOKEN = re.compile(r"^[A-Za-z0-9_-]{43}$")
KINDS = {"contact_report", "message_report", "support"}
STATES = {"open", "reviewing", "answered", "closed"}
FIELDS = {"version", "id", "secret", "kind", "reason", "details", "contactName", "selectedText", "messageType", "consent", "consentVersion"}


class Invalid(Exception):
    pass


class Capacity(Exception):
    pass


def clean(value, maximum, required=False):
    if not isinstance(value, str) or len(value) > maximum:
        raise Invalid("Invalid field length or type")
    if any(ord(c) < 32 and c not in "\n\t" for c in value):
        raise Invalid("Control characters are not accepted")
    value = value.strip()
    if required and not value:
        raise Invalid("Required field is empty")
    return value


def validate(data):
    if not isinstance(data, dict) or set(data) - FIELDS:
        raise Invalid("Unsupported fields")
    if type(data.get("version")) is not int or data["version"] != 1:
        raise Invalid("Unsupported request version")
    if data.get("consent") is not True or data.get("consentVersion") != CONSENT_VERSION:
        raise Invalid("Review and consent are required")
    try:
        request_id = str(uuid.UUID(data["id"]))
    except (ValueError, KeyError, TypeError, AttributeError) as error:
        raise Invalid("Invalid request identifier") from error
    secret = data.get("secret")
    if not isinstance(secret, str) or not TOKEN.fullmatch(secret):
        raise Invalid("Invalid access credential")
    if not isinstance(data.get("kind"), str) or data["kind"] not in KINDS:
        raise Invalid("Invalid request category")
    payload = {"kind": data["kind"], "reason": clean(data.get("reason", ""), 120, True), "details": clean(data.get("details", ""), 4000, data["kind"] == "support")}
    for field, size in (("contactName", 128), ("selectedText", 4000), ("messageType", 64)):
        if field in data:
            payload[field] = clean(data[field], size, True)
    if data["kind"] == "support" and any(k in payload for k in ("contactName", "selectedText", "messageType")):
        raise Invalid("Support requests must not attach chat data")
    if data["kind"] != "message_report" and any(k in payload for k in ("selectedText", "messageType")):
        raise Invalid("Only a selected message report may include message data")
    return request_id, secret, payload


class Store:
    def __init__(self, path, retention_days=30, max_tickets=1000, daily_limit=500):
        self.path = str(path)
        self.retention_days = retention_days
        self.max_tickets = max_tickets
        self.daily_limit = daily_limit
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS tickets (
              id TEXT PRIMARY KEY, reference TEXT UNIQUE NOT NULL, secret_hash TEXT NOT NULL,
              payload TEXT NOT NULL, consent_version TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT 'open', created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL, notified_at INTEGER,
              replies TEXT NOT NULL DEFAULT '[]', notes TEXT NOT NULL DEFAULT '[]'
            );
            CREATE INDEX IF NOT EXISTS tickets_updated ON tickets(updated_at);
            CREATE INDEX IF NOT EXISTS tickets_created ON tickets(created_at);
            """)
        os.chmod(self.path, 0o600)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=5)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA secure_delete=ON")
        try:
            with db:
                yield db
        finally:
            db.close()

    @staticmethod
    def digest(secret):
        return hashlib.sha256(secret.encode("ascii")).hexdigest()

    def create(self, data, now=None):
        ticket_id, secret, payload = validate(data)
        now = int(time.time() if now is None else now)
        serialized = json.dumps(payload, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
        secret_hash = self.digest(secret)
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            existing = db.execute("SELECT * FROM tickets WHERE id=?", (ticket_id,)).fetchone()
            if existing:
                if not hmac.compare_digest(existing["secret_hash"], secret_hash) or existing["payload"] != serialized:
                    raise Invalid("Request identifier is already in use")
                if existing["updated_at"] < now - self.retention_days * 86400:
                    raise Invalid("This receipt has expired")
                return self.public(existing), False
            total = db.execute("SELECT count(*) FROM tickets").fetchone()[0]
            daily = db.execute("SELECT count(*) FROM tickets WHERE created_at >= ?", (now - 86400,)).fetchone()[0]
            recent = db.execute("SELECT count(*) FROM tickets WHERE created_at >= ?", (now - 60,)).fetchone()[0]
            if total >= self.max_tickets or daily >= self.daily_limit or recent >= 10:
                raise Capacity()
            reference = "XX-" + ticket_id.replace("-", "").upper()
            db.execute("INSERT INTO tickets(id,reference,secret_hash,payload,consent_version,created_at,updated_at) VALUES(?,?,?,?,?,?,?)", (ticket_id, reference, secret_hash, serialized, CONSENT_VERSION, now, now))
            row = db.execute("SELECT * FROM tickets WHERE id=?", (ticket_id,)).fetchone()
            return self.public(row), True

    def get(self, ticket_id, secret, now=None):
        if not isinstance(secret, str) or not TOKEN.fullmatch(secret):
            return None
        now = int(time.time() if now is None else now)
        with self.connect() as db:
            row = db.execute("SELECT * FROM tickets WHERE id=? AND updated_at>=?", (ticket_id, now - self.retention_days * 86400)).fetchone()
            expected = row["secret_hash"] if row else "0" * 64
            matched = hmac.compare_digest(expected, self.digest(secret))
            return self.public(row) if matched and row else None

    def public(self, row):
        return {"id": row["id"], "reference": row["reference"], "status": row["status"], "createdAt": row["created_at"], "updatedAt": row["updated_at"], "expiresAt": row["updated_at"] + self.retention_days * 86400, "replies": json.loads(row["replies"])}

    def prune(self, now=None):
        now = int(time.time() if now is None else now)
        with self.connect() as db:
            count = db.execute("DELETE FROM tickets WHERE updated_at < ?", (now - self.retention_days * 86400,)).rowcount
        if count:
            with self.connect() as db:
                db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        return count

    def followup(self, ticket_id, secret, data):
        if not isinstance(data, dict) or set(data) != {"id", "text", "consent", "consentVersion"}:
            raise Invalid("Invalid follow-up fields")
        if data["consent"] is not True or data["consentVersion"] != CONSENT_VERSION:
            raise Invalid("Consent is required")
        try:
            message_id = str(uuid.UUID(data["id"]))
        except (ValueError, TypeError, AttributeError) as error:
            raise Invalid("Invalid follow-up identifier") from error
        text = clean(data["text"], 4000, True)
        if not isinstance(secret, str) or not TOKEN.fullmatch(secret):
            return None
        now = int(time.time())
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM tickets WHERE id=? AND updated_at>=?", (ticket_id, now - self.retention_days * 86400)).fetchone()
            expected = row["secret_hash"] if row else "0" * 64
            if not hmac.compare_digest(expected, self.digest(secret)) or not row:
                return None
            replies = json.loads(row["replies"])
            existing = next((r for r in replies if r.get("id") == message_id), None)
            if existing:
                if existing["text"] != text or existing.get("sender") != "requester":
                    raise Invalid("Follow-up identifier is already in use")
                return self.public(row)
            if len(replies) >= 30 or sum(r["createdAt"] >= now - 3600 and r.get("sender") == "requester" for r in replies) >= 5:
                raise Capacity()
            replies.append({"id": message_id, "text": text, "createdAt": now, "sender": "requester"})
            db.execute("UPDATE tickets SET replies=?,status='open',updated_at=?,notified_at=NULL WHERE id=?", (json.dumps(replies), now, ticket_id))
            return self.public(db.execute("SELECT * FROM tickets WHERE id=?", (ticket_id,)).fetchone())


class SupportApp:
    def __init__(self, store, public_url, contact, public_dir=None):
        parsed = urlsplit(public_url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.path not in ("", "/") or parsed.username or parsed.query or parsed.fragment:
            raise ValueError("A public HTTPS origin is required")
        if not re.fullmatch(r"[^\s@<>\r\n]+@[^\s@<>\r\n]+\.[^\s@<>\r\n]+", contact):
            raise ValueError("A monitored contact email is required")
        self.store = store
        self.origin = public_url.rstrip("/")
        self.contact = contact
        self.public_dir = Path(public_dir or Path(__file__).with_name("public"))

    def __call__(self, environ, start_response):
        headers = [("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer"), ("X-Frame-Options", "DENY"), ("Cross-Origin-Resource-Policy", "same-origin"), ("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")]

        def response(status, value, mime="application/json; charset=utf-8", extra=()):
            body = json.dumps(value, ensure_ascii=True).encode() if isinstance(value, (dict, list)) else value
            start_response(status, headers + [("Content-Type", mime), ("Content-Length", str(len(body)))] + list(extra))
            return [body]

        try:
            method, path = environ.get("REQUEST_METHOD"), environ.get("PATH_INFO", "")
            if environ.get("QUERY_STRING"):
                return response("400 Bad Request", {"error": "Query parameters are not supported"})
            origin = environ.get("HTTP_ORIGIN")
            if origin and origin != self.origin:
                return response("403 Forbidden", {"error": "Origin is not permitted"})
            if method == "GET" and path == "/healthz":
                with self.store.connect() as db:
                    db.execute("SELECT 1").fetchone()
                return response("200 OK", {"status": "ok"})
            if method == "GET" and path == "/api/v1/policy":
                return response("200 OK", {"consentVersion": CONSENT_VERSION, "contact": self.contact, "retentionDays": self.store.retention_days, "maxDetailsLength": 4000})
            if method == "GET" and path in ("/", "/support", "/privacy", "/rules", "/app.js", "/style.css"):
                name, mime = {"/app.js": ("app.js", "text/javascript; charset=utf-8"), "/style.css": ("style.css", "text/css; charset=utf-8")}.get(path, ("index.html", "text/html; charset=utf-8"))
                body = (self.public_dir / name).read_bytes()
                if name == "index.html":
                    body = body.decode().replace("{{CONTACT}}", html.escape(self.contact, quote=True)).replace("{{DAYS}}", str(self.store.retention_days)).encode()
                return response("200 OK", body, mime)
            followup = re.fullmatch(r"/api/v1/tickets/([0-9a-f-]{36})/messages", path)
            if method == "POST" and (path == "/api/v1/tickets" or followup):
                if environ.get("CONTENT_TYPE", "").split(";")[0].strip() != "application/json":
                    return response("415 Unsupported Media Type", {"error": "JSON is required"})
                try:
                    size = int(environ.get("CONTENT_LENGTH", "0"))
                except ValueError:
                    size = 0
                if not 0 < size <= MAX_BODY:
                    return response("413 Payload Too Large", {"error": "Request exceeds the limit"})
                raw = environ["wsgi.input"].read(size)
                if len(raw) != size:
                    raise Invalid("Incomplete request")
                def unique_pairs(pairs):
                    result = {}
                    for key, value in pairs:
                        if key in result:
                            raise Invalid("Duplicate JSON fields")
                        result[key] = value
                    return result
                data = json.loads(raw, object_pairs_hook=unique_pairs)
                if followup:
                    auth = environ.get("HTTP_AUTHORIZATION", "")
                    ticket = self.store.followup(followup[1], auth[7:] if auth.startswith("Bearer ") else "", data)
                    return response("200 OK", ticket) if ticket else response("404 Not Found", {"error": "Receipt not found or expired"})
                ticket, created = self.store.create(data)
                return response("201 Created" if created else "200 OK", ticket)
            match = re.fullmatch(r"/api/v1/tickets/([0-9a-f-]{36})", path)
            if method == "GET" and match:
                auth = environ.get("HTTP_AUTHORIZATION", "")
                ticket = self.store.get(match[1], auth[7:] if auth.startswith("Bearer ") else "")
                return response("200 OK", ticket) if ticket else response("404 Not Found", {"error": "Receipt not found or expired"})
            return response("404 Not Found", {"error": "Not found"})
        except (Invalid, json.JSONDecodeError, UnicodeError, RecursionError):
            return response("400 Bad Request", {"error": "Review the request fields and consent"})
        except Capacity:
            return response("429 Too Many Requests", {"error": "Intake is temporarily busy; keep the receipt and retry later"}, extra=[("Retry-After", "60")])
        except (sqlite3.Error, OSError):
            return response("503 Service Unavailable", {"error": "Support is temporarily unavailable; retry with the same receipt"}, extra=[("Retry-After", "60")])


def configured_store():
    days = int(os.environ.get("SUPPORT_RETENTION_DAYS", "30"))
    if not 7 <= days <= 365:
        raise ValueError("Invalid retention period")
    return Store(os.environ.get("SUPPORT_DATABASE", "/data/support.sqlite3"), days)


_app = None
_lock = threading.Lock()


def application(environ, start_response):
    global _app
    with _lock:
        if _app is None:
            _app = SupportApp(configured_store(), os.environ["SUPPORT_PUBLIC_URL"], os.environ["SUPPORT_CONTACT_EMAIL"])
    return _app(environ, start_response)
