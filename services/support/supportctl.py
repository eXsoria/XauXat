"""Private operator console. Never expose this as an HTTP endpoint."""
import argparse
from email.message import EmailMessage
import json
import os
from pathlib import Path
import smtplib
import ssl
import sys
import time
import uuid

from support import STATES, clean, configured_store


def notify(store):
    """Send metadata-only alerts. Report bodies and receipt secrets stay off email."""
    required = ("SUPPORT_SMTP_HOST", "SUPPORT_ALERT_EMAIL", "SUPPORT_FROM_EMAIL")
    if not all(os.environ.get(k) for k in required):
        raise SystemExit("SMTP alerts are not configured; check the private inbox with supportctl list.")
    for key in ("SUPPORT_ALERT_EMAIL", "SUPPORT_FROM_EMAIL"):
        if any(c in os.environ[key] for c in "\r\n"):
            raise SystemExit("Invalid email configuration")
    # One scheduled operator process at a time; keep the transaction short and
    # retry on failure. SMTP acceptance followed by a crash can duplicate an alert.
    with store.connect() as db:
        rows = db.execute("SELECT id,reference,created_at,replies FROM tickets WHERE notified_at IS NULL AND status!='closed' ORDER BY created_at LIMIT 20").fetchall()
    sent = 0
    for row in rows:
        message = EmailMessage()
        message["From"] = os.environ["SUPPORT_FROM_EMAIL"]
        message["To"] = os.environ["SUPPORT_ALERT_EMAIL"]
        message["Subject"] = "XauXat: new request " + row["reference"]
        message.set_content("A new request is waiting in the private XauXat support inbox.\nReference: " + row["reference"] + "\nReview it through the SSH operator console. No report content is included in this email.\n")
        port = int(os.environ.get("SUPPORT_SMTP_PORT", "587"))
        context = ssl.create_default_context()
        transport = smtplib.SMTP_SSL if port == 465 else smtplib.SMTP
        try:
            options = {"context": context} if port == 465 else {}
            with transport(os.environ["SUPPORT_SMTP_HOST"], port, timeout=10, **options) as smtp:
                if port != 465:
                    smtp.starttls(context=context)
                if os.environ.get("SUPPORT_SMTP_USER"):
                    smtp.login(os.environ["SUPPORT_SMTP_USER"], os.environ["SUPPORT_SMTP_PASSWORD"])
                smtp.send_message(message)
        except (OSError, smtplib.SMTPException):
            print("Alert delivery failed; queued for retry.", file=sys.stderr)
            continue
        with store.connect() as db:
            db.execute("UPDATE tickets SET notified_at=? WHERE id=? AND replies=?", (int(time.time()), row["id"], row["replies"]))
        sent += 1
    return sent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("list", "show", "reply", "note", "status", "maintenance"))
    parser.add_argument("reference", nargs="?")
    parser.add_argument("--text-file", type=Path)
    parser.add_argument("--state", choices=sorted(STATES))
    args = parser.parse_args()
    store = configured_store()
    if args.action == "maintenance":
        print("Expired requests removed:", store.prune())
        print("Alerts accepted by SMTP:", notify(store))
        return
    store.prune()
    with store.connect() as db:
        if args.action in ("reply", "note", "status"):
            db.execute("BEGIN IMMEDIATE")
        if args.action == "list":
            rows = db.execute("SELECT reference,status,created_at,updated_at,notified_at FROM tickets ORDER BY created_at DESC LIMIT 100").fetchall()
            print(json.dumps([dict(row) for row in rows], indent=2, ensure_ascii=True))
            return
        row = db.execute("SELECT * FROM tickets WHERE reference=?", (args.reference,)).fetchone()
        if row is None:
            raise SystemExit("Reference not found")
        if args.action == "show":
            result = {k: row[k] for k in ("reference", "status", "created_at", "updated_at", "payload", "replies", "notes")}
            for key in ("payload", "replies", "notes"):
                result[key] = json.loads(result[key])
            # Escaping terminal controls is intentional: report text is untrusted.
            print(json.dumps(result, indent=2, ensure_ascii=True))
            return
        if args.action in ("reply", "note"):
            if args.text_file is None:
                parser.error("--text-file is required")
            text = clean(args.text_file.read_text(encoding="utf-8"), 4000, True)
            column = "replies" if args.action == "reply" else "notes"
            entries = json.loads(row[column])
            if len(entries) >= 30:
                raise SystemExit("Entry limit reached")
            entries.append({"id": str(uuid.uuid4()), "text": text, "createdAt": int(time.time()), "sender": "support"})
            state = "answered" if args.action == "reply" else row["status"]
            db.execute(f"UPDATE tickets SET {column}=?,status=?,updated_at=? WHERE id=?", (json.dumps(entries), state, int(time.time()), row["id"]))
        else:
            if args.state is None:
                parser.error("--state is required")
            db.execute("UPDATE tickets SET status=?,updated_at=? WHERE id=?", (args.state, int(time.time()), row["id"]))
        print("Updated:", row["reference"])


if __name__ == "__main__":
    main()
