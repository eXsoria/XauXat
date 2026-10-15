import io
import json
import os
from pathlib import Path
import secrets
import smtplib
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

from support import Capacity, Invalid, Store, SupportApp
import supportctl


class SupportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = Store(Path(self.temp.name) / "support.sqlite3")
        self.app = SupportApp(self.store, "https://support.example.test", "operator@example.test")

    def submission(self, **extra):
        return {"version": 1, "id": str(uuid.uuid4()), "secret": secrets.token_urlsafe(32), "kind": "contact_report", "reason": "Spam", "details": "", "consent": True, "consentVersion": "2026-10-15", **extra}

    def call(self, method, path, data=None, raw=None, headers=None, query=""):
        body = raw if raw is not None else json.dumps(data).encode() if data is not None else b""
        environ = {"REQUEST_METHOD": method, "PATH_INFO": path, "CONTENT_TYPE": "application/json", "CONTENT_LENGTH": str(len(body)), "wsgi.input": io.BytesIO(body), "QUERY_STRING": query, **(headers or {})}
        result = []
        response = b"".join(self.app(environ, lambda status, values: result.extend((status, dict(values)))))
        return result[0], result[1], json.loads(response) if result[1]["Content-Type"].startswith("application/json") else response

    def test_minimal_submission_and_secret_hash_only(self):
        data = self.submission()
        status, _, result = self.call("POST", "/api/v1/tickets", data)
        self.assertEqual(status, "201 Created")
        self.assertEqual(result["status"], "open")
        self.assertNotIn("secret", result)
        self.assertNotIn("payload", result)
        with self.store.connect() as db:
            row = db.execute("SELECT * FROM tickets").fetchone()
            self.assertNotEqual(row["secret_hash"], data["secret"])
            self.assertEqual(json.loads(row["payload"]), {"kind": "contact_report", "reason": "Spam", "details": ""})
            self.assertNotIn(data["secret"], "\n".join(db.iterdump()))

    def test_explicit_selected_text_only(self):
        data = self.submission(kind="message_report", contactName="Chosen name", selectedText="Only this message", messageType="Text")
        self.assertEqual(self.call("POST", "/api/v1/tickets", data)[0], "201 Created")
        with self.store.connect() as db:
            payload = json.loads(db.execute("SELECT payload FROM tickets").fetchone()[0])
        self.assertEqual(payload["selectedText"], "Only this message")
        self.assertEqual(payload["contactName"], "Chosen name")

    def test_consent_is_required(self):
        for extra in ({"consent": False}, {"consent": "true"}, {"consentVersion": "old"}):
            with self.subTest(extra=extra):
                self.assertEqual(self.call("POST", "/api/v1/tickets", self.submission(**extra))[0], "400 Bad Request")

    def test_unexpected_private_fields_rejected(self):
        for name in ("profileId", "messages", "deviceToken", "file", "chatId", "history"):
            with self.subTest(name=name):
                self.assertEqual(self.call("POST", "/api/v1/tickets", self.submission(**{name: "must not be accepted"}))[0], "400 Bad Request")

    def test_idempotent_retry_and_conflicting_reuse(self):
        data = self.submission()
        first = self.call("POST", "/api/v1/tickets", data)
        second = self.call("POST", "/api/v1/tickets", data)
        self.assertEqual(first[2]["reference"], second[2]["reference"])
        self.assertEqual(second[0], "200 OK")
        for change in ({"secret": secrets.token_urlsafe(32)}, {"details": "changed"}):
            self.assertEqual(self.call("POST", "/api/v1/tickets", data | change)[0], "400 Bad Request")
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM tickets").fetchone()[0], 1)

    def test_private_receipt_required_and_not_accepted_in_url(self):
        data = self.submission()
        self.store.create(data)
        path = "/api/v1/tickets/" + data["id"]
        self.assertEqual(self.call("GET", path)[0], "404 Not Found")
        self.assertEqual(self.call("GET", path, headers={"HTTP_AUTHORIZATION": "Bearer " + secrets.token_urlsafe(32)})[0], "404 Not Found")
        self.assertEqual(self.call("GET", path, query="secret=" + data["secret"])[0], "400 Bad Request")
        result = self.call("GET", path, headers={"HTTP_AUTHORIZATION": "Bearer " + data["secret"]})
        self.assertEqual(result[0], "200 OK")
        self.assertNotIn(data["secret"], json.dumps(result[2]))

    def test_expiration_and_actual_prune(self):
        data = self.submission()
        self.store.create(data, now=100)
        self.assertIsNone(self.store.get(data["id"], data["secret"], now=100 + 31 * 86400))
        self.assertEqual(self.store.prune(now=100 + 31 * 86400), 1)
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM tickets").fetchone()[0], 0)

    def test_global_rate_and_storage_bounds(self):
        for n in range(10):
            self.store.create(self.submission(), now=100)
        with self.assertRaises(Capacity):
            self.store.create(self.submission(), now=100)
        self.store.max_tickets = 10
        with self.assertRaises(Capacity):
            self.store.create(self.submission(), now=200)
        self.store.max_tickets = 100
        self.store.daily_limit = 10
        with self.assertRaises(Capacity):
            self.store.create(self.submission(), now=200)

    def test_body_limits_json_duplicates_and_invalid_types(self):
        self.assertEqual(self.call("POST", "/api/v1/tickets", raw=b"x" * 24577)[0], "413 Payload Too Large")
        self.assertEqual(self.call("POST", "/api/v1/tickets", raw=b'{"version":1,"version":1}')[0], "400 Bad Request")
        self.assertEqual(self.call("POST", "/api/v1/tickets", raw=b"not json")[0], "400 Bad Request")
        for extra in ({"kind": []}, {"details": "\x1b[31m"}, {"reason": "x" * 121}, {"kind": "support", "details": ""}, {"kind": "support", "details": "help", "contactName": "not allowed"}):
            with self.subTest(extra=extra):
                self.assertEqual(self.call("POST", "/api/v1/tickets", self.submission(**extra))[0], "400 Bad Request")

    def test_no_cross_origin_access_or_public_admin(self):
        self.assertEqual(self.call("POST", "/api/v1/tickets", self.submission(), headers={"HTTP_ORIGIN": "https://attacker.test"})[0], "403 Forbidden")
        for path in ("/admin", "/api/v1/tickets", "/data/support.sqlite3"):
            self.assertEqual(self.call("GET", path)[0], "404 Not Found")

    def test_public_contact_policy_and_security_headers(self):
        status, headers, body = self.call("GET", "/privacy")
        self.assertEqual(status, "200 OK")
        self.assertIn(b"operator@example.test", body)
        self.assertNotIn(b"{{CONTACT}}", body)
        self.assertIn(b"30 days", body)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(headers["X-Frame-Options"], "DENY")
        self.assertNotIn("Access-Control-Allow-Origin", headers)
        self.assertEqual(self.call("GET", "/api/v1/policy")[2]["retentionDays"], 30)

    def test_public_reply_excludes_operator_notes(self):
        data = self.submission()
        ticket, _ = self.store.create(data)
        text_file = Path(self.temp.name) / "reply.txt"
        text_file.write_text("We reviewed your request.", encoding="utf-8")
        with patch.dict(os.environ, {"SUPPORT_DATABASE": self.store.path}), patch("sys.argv", ["supportctl", "reply", ticket["reference"], "--text-file", str(text_file)]):
            supportctl.main()
        text_file.write_text("PRIVATE OPERATOR NOTE", encoding="utf-8")
        with patch.dict(os.environ, {"SUPPORT_DATABASE": self.store.path}), patch("sys.argv", ["supportctl", "note", ticket["reference"], "--text-file", str(text_file)]):
            supportctl.main()
        result = self.store.get(data["id"], data["secret"])
        self.assertEqual(result["status"], "answered")
        self.assertEqual(result["replies"][0]["text"], "We reviewed your request.")
        self.assertNotIn("PRIVATE OPERATOR NOTE", json.dumps(result))

    def test_followup_requires_receipt_consent_and_is_idempotent(self):
        data = self.submission()
        self.store.create(data)
        path = "/api/v1/tickets/" + data["id"] + "/messages"
        auth = {"HTTP_AUTHORIZATION": "Bearer " + data["secret"]}
        message = {"id": str(uuid.uuid4()), "text": "Here is the information you asked for.", "consent": True, "consentVersion": "2026-10-15"}
        self.assertEqual(self.call("POST", path, message)[0], "404 Not Found")
        self.assertEqual(self.call("POST", path, message | {"consent": False}, headers=auth)[0], "400 Bad Request")
        first = self.call("POST", path, message, headers=auth)
        self.assertEqual(first[0], "200 OK")
        self.assertEqual(first[2]["replies"][0]["sender"], "requester")
        retry = self.call("POST", path, message, headers=auth)
        self.assertEqual(len(retry[2]["replies"]), 1)
        self.assertEqual(self.call("POST", path, message | {"text": "altered"}, headers=auth)[0], "400 Bad Request")
        self.assertEqual(self.call("POST", path, message | {"file": "forbidden"}, headers=auth)[0], "400 Bad Request")

    def test_followup_reopens_and_requeues_without_private_data_in_alert(self):
        data = self.submission()
        self.store.create(data)
        with self.store.connect() as db:
            db.execute("UPDATE tickets SET status='closed',notified_at=1")
        self.store.followup(data["id"], data["secret"], {"id": str(uuid.uuid4()), "text": "New information", "consent": True, "consentVersion": "2026-10-15"})
        with self.store.connect() as db:
            row = db.execute("SELECT status,notified_at FROM tickets").fetchone()
        self.assertEqual(row["status"], "open")
        self.assertIsNone(row["notified_at"])

    def test_followup_rate_limit_and_expired_receipt(self):
        data = self.submission()
        self.store.create(data)
        for n in range(5):
            self.store.followup(data["id"], data["secret"], {"id": str(uuid.uuid4()), "text": str(n), "consent": True, "consentVersion": "2026-10-15"})
        with self.assertRaises(Capacity):
            self.store.followup(data["id"], data["secret"], {"id": str(uuid.uuid4()), "text": "one too many", "consent": True, "consentVersion": "2026-10-15"})
        with self.store.connect() as db:
            db.execute("UPDATE tickets SET updated_at=1")
        self.assertIsNone(self.store.followup(data["id"], data["secret"], {"id": str(uuid.uuid4()), "text": "expired", "consent": True, "consentVersion": "2026-10-15"}))

    def test_alerts_do_not_forward_report_content_and_retry_failures(self):
        data = self.submission(details="PRIVATE DESCRIPTION", contactName="PRIVATE PERSON")
        self.store.create(data)
        env = {"SUPPORT_SMTP_HOST": "smtp.example.test", "SUPPORT_ALERT_EMAIL": "operator@example.test", "SUPPORT_FROM_EMAIL": "alerts@example.test"}
        with patch.dict(os.environ, env), patch.object(smtplib, "SMTP") as smtp:
            smtp.return_value.__enter__.return_value.send_message.side_effect = smtplib.SMTPException("test")
            self.assertEqual(supportctl.notify(self.store), 0)
            smtp.return_value.__enter__.return_value.send_message.side_effect = None
            self.assertEqual(supportctl.notify(self.store), 1)
            sent = smtp.return_value.__enter__.return_value.send_message.call_args.args[0].as_string()
            self.assertNotIn("PRIVATE DESCRIPTION", sent)
            self.assertNotIn("PRIVATE PERSON", sent)
            self.assertNotIn(data["secret"], sent)
            smtp.return_value.__enter__.return_value.starttls.assert_called()
            self.assertEqual(supportctl.notify(self.store), 0)

    def test_followup_arriving_during_alert_delivery_remains_queued(self):
        data = self.submission()
        self.store.create(data)
        env = {"SUPPORT_SMTP_HOST": "smtp.example.test", "SUPPORT_ALERT_EMAIL": "operator@example.test", "SUPPORT_FROM_EMAIL": "alerts@example.test"}
        def concurrent_followup(_message):
            self.store.followup(data["id"], data["secret"], {"id": str(uuid.uuid4()), "text": "Arrived during SMTP delivery", "consent": True, "consentVersion": "2026-10-15"})
        with patch.dict(os.environ, env), patch.object(smtplib, "SMTP") as smtp:
            smtp.return_value.__enter__.return_value.send_message.side_effect = concurrent_followup
            self.assertEqual(supportctl.notify(self.store), 1)
        with self.store.connect() as db:
            self.assertIsNone(db.execute("SELECT notified_at FROM tickets").fetchone()[0])

    def test_early_deletion_requires_matching_private_receipt(self):
        data = self.submission()
        ticket, _ = self.store.create(data)
        receipt_file = Path(self.temp.name) / "receipt.txt"
        args = ["supportctl", "delete", ticket["reference"], "--receipt-file", str(receipt_file), "--confirm-delete"]
        receipt_file.write_text(data["id"] + "." + secrets.token_urlsafe(32), encoding="utf-8")
        with patch.dict(os.environ, {"SUPPORT_DATABASE": self.store.path}), patch("sys.argv", args):
            with self.assertRaises(SystemExit):
                supportctl.main()
        self.assertIsNotNone(self.store.get(data["id"], data["secret"]))
        receipt_file.write_text(data["id"] + "." + data["secret"], encoding="utf-8")
        with patch.dict(os.environ, {"SUPPORT_DATABASE": self.store.path}), patch("sys.argv", args):
            supportctl.main()
        self.assertIsNone(self.store.get(data["id"], data["secret"]))

    def test_maintenance_failure_is_visible_when_alerts_remain_queued(self):
        self.store.create(self.submission())
        with patch.dict(os.environ, {"SUPPORT_DATABASE": self.store.path}), patch("sys.argv", ["supportctl", "maintenance"]), patch.object(supportctl, "notify", return_value=0):
            with self.assertRaisesRegex(SystemExit, "Alerts remain queued"):
                supportctl.main()


if __name__ == "__main__":
    unittest.main()
