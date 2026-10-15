"""Exercise the real local Gunicorn container with synthetic data only."""
import json
import secrets
import sys
import urllib.error
import urllib.request
from urllib.parse import urlsplit
import uuid

origin = sys.argv[1].rstrip("/")
parsed = urlsplit(origin)
assert parsed.scheme == "http" and parsed.hostname == "127.0.0.1" and parsed.port and not parsed.username and not parsed.password and not parsed.query and not parsed.fragment and parsed.path in ("", "/"), "This synthetic test is restricted to a local container"
secret = secrets.token_urlsafe(32)
ticket_id = str(uuid.uuid4())
data = {"version": 1, "id": ticket_id, "secret": secret, "kind": "support", "reason": "CI integration smoke test", "details": "Synthetic fixture; no real user data", "consent": True, "consentVersion": "2026-10-15"}
request = urllib.request.Request(origin + "/api/v1/tickets", json.dumps(data).encode(), {"Content-Type": "application/json"})
with urllib.request.urlopen(request, timeout=5) as response:
    assert response.status == 201
    ticket = json.load(response)
assert ticket["id"] == ticket_id
private = urllib.request.Request(origin + "/api/v1/tickets/" + ticket_id, headers={"Authorization": "Bearer " + secret})
with urllib.request.urlopen(private, timeout=5) as response:
    assert json.load(response)["reference"] == ticket["reference"]
try:
    urllib.request.urlopen(origin + "/api/v1/tickets/" + ticket_id, timeout=5)
except urllib.error.HTTPError as error:
    assert error.code == 404
else:
    raise AssertionError("A private receipt must be required")
print("Real WSGI container intake and receipt authentication passed.")
