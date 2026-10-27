"""Verify TestFlight uploads with the existing CI key; never print credentials."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request

APP = "6813277167"
BUNDLE = "pt.exsoria.xauxat"
INTERNAL = "059dd613-616d-48d7-bec3-f5fb0808c5f1"


def encoded(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def raw_signature(der):
    if len(der) < 6 or der[0] != 0x30 or der[1] != len(der) - 2:
        raise ValueError("Invalid ES256 signature")
    offset, components = 2, []
    for _ in range(2):
        if der[offset] != 2:
            raise ValueError("Invalid ES256 integer")
        length = der[offset + 1]
        value = der[offset + 2:offset + 2 + length]
        if not value or value[0] & 0x80 or len(value) != length:
            raise ValueError("Invalid ES256 integer")
        components.append(int.from_bytes(value, "big").to_bytes(32, "big"))
        offset += 2 + length
    if offset != len(der):
        raise ValueError("Trailing ES256 data")
    return b"".join(components)


class Apple:
    def __call__(self, path, method="GET", data=None):
        now = int(time.time())
        header = encoded(json.dumps({"alg": "ES256", "kid": os.environ["APP_STORE_CONNECT_KEY_ID"], "typ": "JWT"}).encode())
        claims = encoded(json.dumps({"iss": os.environ["APP_STORE_CONNECT_ISSUER_ID"], "iat": now - 10,
                                     "exp": now + 600, "aud": "appstoreconnect-v1"}).encode())
        message = header + "." + claims
        signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.environ["APP_STORE_CONNECT_KEY_PATH"]],
                                   input=message.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout
        token = message + "." + encoded(raw_signature(signature))
        request = urllib.request.Request("https://api.appstoreconnect.apple.com/" + path,
            data=None if data is None else json.dumps(data).encode(), method=method,
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read()
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as error:
            raise RuntimeError("App Store Connect HTTP " + str(error.code)) from None


def preflight(api, number):
    apps = api("v1/apps?filter[bundleId]=" + BUNDLE)["data"]
    if len(apps) != 1 or apps[0]["id"] != APP:
        raise RuntimeError("Unexpected App Store application")
    builds = api("v1/builds?filter[app]=" + APP + "&sort=-uploadedDate&limit=200")
    versions = [b["attributes"]["version"] for b in builds["data"]]
    if any(not v.isdigit() for v in versions):
        raise RuntimeError("Review non-numeric App Store build numbers")
    latest = max(map(int, versions), default=0)
    if number <= latest:
        raise RuntimeError("Build number already used or older than the latest upload: " + str(latest))
    return {"app_id": APP, "build_number": number, "previous_build_number": latest, "unused": True}


def wait_ready(api, number, timeout=1200):
    deadline = time.monotonic() + timeout
    while True:
        builds = api("v1/builds?filter[app]=" + APP + "&filter[version]=" + str(number))["data"]
        if len(builds) > 1:
            raise RuntimeError("Ambiguous uploaded build")
        if builds:
            build = builds[0]
            state = build["attributes"]["processingState"]
            if state in ("FAILED", "INVALID"):
                raise RuntimeError("Apple processing failed: " + state)
            if state == "VALID":
                if build["attributes"]["expired"]:
                    raise RuntimeError("The uploaded build is expired")
                return build
        if time.monotonic() >= deadline:
            raise RuntimeError("Upload accepted; Apple processing still pending. Inspect the existing build before retrying.")
        time.sleep(20)


def publish_internal(api, build, notes):
    bid = build["id"]
    train = api("v1/builds/" + bid + "/preReleaseVersion")["data"]["attributes"]
    if train["platform"] != "IOS" or build["attributes"].get("usesNonExemptEncryption") is not False:
        raise RuntimeError("Review the uploaded platform or encryption declaration")
    groups = api("v1/apps/" + APP + "/betaGroups")["data"]
    group = next(g for g in groups if g["id"] == INTERNAL)
    if group["attributes"]["name"] != "XauXat Internal" or group["attributes"]["isInternalGroup"] is not True:
        raise RuntimeError("Unexpected internal group")
    testers = api("v1/betaGroups/" + INTERNAL + "/betaTesters?limit=200")
    if len(testers["data"]) != 1 or testers.get("links", {}).get("next"):
        raise RuntimeError("Internal group membership changed; upload is ready but distribution needs review")
    localizations = api("v1/builds/" + bid + "/betaBuildLocalizations")["data"]
    existing = [x for x in localizations if x["attributes"]["locale"] == "en-US"]
    if len(existing) > 1:
        raise RuntimeError("Ambiguous build test notes")
    if existing:
        loc = existing[0]
        api("v1/betaBuildLocalizations/" + loc["id"], "PATCH", {"data": {
            "type": "betaBuildLocalizations", "id": loc["id"], "attributes": {"whatsNew": notes}}})
    else:
        api("v1/betaBuildLocalizations", "POST", {"data": {"type": "betaBuildLocalizations",
            "attributes": {"locale": "en-US", "whatsNew": notes},
            "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
    verified = api("v1/builds/" + bid + "/betaBuildLocalizations")["data"]
    if not any(x["attributes"]["locale"] == "en-US" and x["attributes"]["whatsNew"] == notes for x in verified):
        raise RuntimeError("Build test notes were not saved")
    relationship = "v1/betaGroups/" + INTERNAL + "/relationships/builds"
    if not any(b["id"] == bid for b in api(relationship)["data"]):
        api(relationship, "POST", {"data": [{"type": "builds", "id": bid}]})
    if not any(b["id"] == bid for b in api(relationship)["data"]):
        raise RuntimeError("Internal build association was not saved")
    for attempt in range(30):
        detail = api("v1/builds/" + bid + "/buildBetaDetail")["data"]["attributes"]
        if detail["internalBuildState"] == "IN_BETA_TESTING":
            break
        if attempt == 29:
            raise RuntimeError("Build is associated with the internal group; availability is still pending")
        time.sleep(2)
    return {"app_id": APP, "build_id": bid, "build_number": build["attributes"]["version"],
            "version": train["version"], "processing_state": "VALID", "notes_verified": True,
            "internal_group": INTERNAL, "internal_testers": 1, "internal_build_state": detail["internalBuildState"],
            "testflight_url": "https://appstoreconnect.apple.com/apps/" + APP + "/testflight/ios/" + bid}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["preflight", "publish"])
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--notes", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.build < 1:
        parser.error("A positive build number is required")
    api = Apple()
    if args.mode == "preflight":
        result = preflight(api, args.build)
    else:
        if args.notes is None:
            parser.error("Publish requires test notes")
        notes = args.notes.read_text(encoding="utf-8").strip()
        if not notes or len(notes) > 4000:
            parser.error("Test notes must contain 1 to 4000 characters")
        result = publish_internal(api, wait_ready(api, args.build), notes)
    result["source_sha"] = os.environ.get("GITHUB_SHA")
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
