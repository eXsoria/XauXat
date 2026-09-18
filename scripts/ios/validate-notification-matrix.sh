#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 (--allow-pending|--require-complete) <matrix.json>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
mode=$1
matrix=$2
[[ "$mode" == "--allow-pending" || "$mode" == "--require-complete" ]] || usage
[[ -f "$matrix" ]] || { echo "Matrix not found: $matrix" >&2; exit 2; }

python3 - "$mode" "$matrix" <<'PY'
import json
import sys
from pathlib import Path

mode, path = sys.argv[1], Path(sys.argv[2])
data = json.loads(path.read_text())
errors = []

def require(condition, message):
    if not condition:
        errors.append(message)

require(data.get("schemaVersion") == 1, "schemaVersion must be 1")
require(data.get("issue") == 79, "issue must be 79")

build = data.get("build", {})
for key in ("xauxatCommit", "configuration", "notificationServerRevision", "testedAtUTC"):
    require(isinstance(build.get(key), str) and build.get(key), f"build.{key} is required")

devices = data.get("devices", [])
require([d.get("id") for d in devices] == ["device_a", "device_b"], "exactly device_a and device_b are required")
for device in devices:
    for key in ("model", "iosVersion"):
        require(isinstance(device.get(key), str) and device.get(key), f"{device.get('id')}.{key} is required")

scenarios = data.get("scenarios", [])
require(len(scenarios) >= 20, "at least 20 P0 scenarios are required")
ids = [s.get("id") for s in scenarios]
require(len(ids) == len(set(ids)), "scenario IDs must be unique")

dimensions = {
    "mode": {"instant", "periodic", "off"},
    "appState": {"foreground", "background", "suspended", "terminated"},
    "deviceState": {"locked", "unlocked"},
    "network": {"wifi", "cellular", "wifi_to_cellular", "offline_recovery"},
    "event": {"direct_message", "group_message", "contact_request", "audio_call"},
    "chatState": {"normal", "locked", "hidden"},
    "profileState": {"normal", "protected"},
    "batch": {"single", "grouped"},
    "tokenState": {"current", "renewed"},
    "notificationServer": {"available", "unavailable", "recovered"},
}

for key, required_values in dimensions.items():
    actual = {s.get(key) for s in scenarios}
    missing = required_values - actual
    require(not missing, f"{key} is missing coverage: {sorted(missing)}")

required_privacy = {
    "generic_banner_no_content",
    "generic_callkit_no_contact",
    "suppressed",
    "badge_unchanged",
    "lock_enforced_on_tap",
    "no_direct_relay",
    "route_rechecked",
    "tor_fail_closed",
    "token_replaced",
    "server_failure_safe",
    "server_recovery",
}
privacy = {item for s in scenarios for item in s.get("privacy", [])}
require(not (required_privacy - privacy), f"privacy coverage missing: {sorted(required_privacy - privacy)}")

allowed_results = {"PENDING", "PASS", "FAIL", "BLOCKED"}
for scenario in scenarios:
    scenario_id = scenario.get("id", "<missing>")
    results = scenario.get("results", {})
    require(set(results) == {"device_a", "device_b"}, f"{scenario_id}: both device results are required")
    for device_id, result in results.items():
        require(result in allowed_results, f"{scenario_id}/{device_id}: invalid result {result!r}")
    require(isinstance(scenario.get("evidence"), list), f"{scenario_id}: evidence must be a list")
    require(isinstance(scenario.get("notes"), str), f"{scenario_id}: notes must be a string")

if mode == "--require-complete":
    for key, value in build.items():
        require(value != "TODO", f"build.{key} still contains TODO")
    for device in devices:
        for key in ("model", "iosVersion"):
            require(device.get(key) != "TODO", f"{device.get('id')}.{key} still contains TODO")
    for scenario in scenarios:
        scenario_id = scenario.get("id", "<missing>")
        for device_id, result in scenario.get("results", {}).items():
            require(result == "PASS", f"{scenario_id}/{device_id} is {result}, expected PASS")
        require(bool(scenario.get("evidence")), f"{scenario_id}: evidence is required")

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    sys.exit(1)

pending = sum(
    result == "PENDING"
    for scenario in scenarios
    for result in scenario["results"].values()
)
passed = sum(
    result == "PASS"
    for scenario in scenarios
    for result in scenario["results"].values()
)
print(f"Notification matrix valid: {len(scenarios)} scenarios, {passed} passed results, {pending} pending results.")
PY
