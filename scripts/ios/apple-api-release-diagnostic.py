"""Read-only diagnostics for the existing App Store Connect key; no credential output."""
import importlib.util
import json
import os
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request


def main():
    key = Path(os.environ["RUNNER_TEMP"]) / "xauxat-api-diagnostic.p8"
    key.write_text(os.environ.pop("APP_STORE_CONNECT_KEY_P8"))
    key.chmod(0o600)
    os.environ["APP_STORE_CONNECT_KEY_PATH"] = str(key)
    spec = importlib.util.spec_from_file_location("testflight_status", "scripts/ios/testflight-status.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    original = urllib.request.urlopen
    records = []
    context = {}

    def inspect(request, *args, **kwargs):
        assert request.get_method() == "GET", "Diagnostic requests must be read-only"
        assert urllib.parse.urlsplit(request.full_url).hostname == "api.appstoreconnect.apple.com"
        if context.get("identified"):
            request.add_header("User-Agent", "XauXat-TestFlight-CI/1.0")
        record = {"variant": context["label"]}
        try:
            response = original(request, *args, **kwargs)
            record.update(status=response.status, content_type=response.headers.get_content_type())
            records.append(record)
            print(json.dumps(record), flush=True)
            return response
        except urllib.error.HTTPError as error:
            body = error.read(32768)
            try:
                parsed = json.loads(body)
                errors = parsed.get("errors", [])
            except (ValueError, AttributeError):
                errors = []
            detail = " ".join(str(e.get("detail", "")) for e in errors).lower()
            record.update(
                status=error.code,
                content_type=error.headers.get_content_type(),
                error_codes=[e.get("code") for e in errors],
                indicators={
                    "agreement_or_terms": any(s in detail for s in ("agreement", "contract", "terms")),
                    "permission_or_role": any(s in detail for s in ("permission", "role", "not allow", "access")),
                    "membership": "membership" in detail,
                    "authentication": any(s in detail for s in ("token", "authentication", "signature")),
                    "html_access_denied": not errors and b"access denied" in body.lower(),
                },
            )
            records.append(record)
            print(json.dumps(record), flush=True)
            raise

    urllib.request.urlopen = inspect
    lookup = "v1/apps?" + urllib.parse.urlencode({"filter[bundleId]": module.BUNDLE})
    builds = "v1/builds?" + urllib.parse.urlencode({"filter[app]": module.APP, "sort": "-uploadedDate", "limit": 5})
    variants = [
        ("raw_app_lookup", "v1/apps?filter[bundleId]=" + module.BUNDLE, False),
        ("encoded_app_lookup", lookup, False),
        ("direct_app", "v1/apps/" + module.APP, False),
        ("encoded_build_list", builds, False),
        ("encoded_lookup_identified", lookup, True),
    ]
    try:
        for label, path, identified in variants:
            context.update(label=label, identified=identified)
            try:
                result = module.Apple()(path)
                data = result.get("data", [])
                if label == "direct_app":
                    print(json.dumps({"variant": label, "expected_app": data.get("id") == module.APP,
                                      "expected_bundle": data.get("attributes", {}).get("bundleId") == module.BUNDLE}), flush=True)
                elif label == "encoded_build_list":
                    print(json.dumps({"variant": label, "builds": [{"number": b.get("attributes", {}).get("version"),
                        "processing": b.get("attributes", {}).get("processingState")} for b in data]}), flush=True)
                else:
                    print(json.dumps({"variant": label, "matching_app": len(data) == 1 and data[0].get("id") == module.APP}), flush=True)
            except RuntimeError as error:
                print(json.dumps({"variant": label, "result": str(error)}), flush=True)
        (Path(os.environ["RUNNER_TEMP"]) / "apple-api-diagnostic.json").write_text(json.dumps(records, indent=2))
    finally:
        urllib.request.urlopen = original
        key.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
