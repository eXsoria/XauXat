#!/usr/bin/env python3
"""Verify the public NTF configuration and the NSE filtering signing contract."""

import argparse
import base64
import binascii
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from urllib.parse import urlsplit

FILTERING = "com.apple.developer.usernotifications.filtering"
SERVER_KEY = "XauXatNotificationServerBase64"
ROOT = Path(__file__).resolve().parents[2]


def read_plist(path):
    with path.open("rb") as stream:
        return plistlib.load(stream)


def validate_server(encoded):
    if not isinstance(encoded, str) or not encoded or "$(" in encoded:
        raise ValueError("notification server setting is empty or unresolved")
    try:
        address = base64.b64decode(encoded, validate=True).decode("ascii")
        parsed = urlsplit(address)
        fingerprint, host = parsed.netloc.split("@")
        digest = base64.b64decode(fingerprint, altchars=b"-_", validate=True)
        if (
            parsed.scheme != "ntf"
            or len(digest) != 32
            or parsed.path
            or parsed.query
            or parsed.fragment
            or not host
            or not parsed.hostname
            or parsed.password is not None
            or (":" in host and parsed.port is None)
            or any(char.isspace() for char in address)
        ):
            raise ValueError("expected an NTF address with a SHA-256 CA fingerprint")
        if parsed.port is not None and parsed.port == 0:
            raise ValueError("notification server port must be between 1 and 65535")
    except (ValueError, UnicodeError, binascii.Error) as error:
        raise ValueError("invalid notification server address") from error
    return address


def verify_profile_settings(project):
    expected = {
        "pt.exsoria.xauxat": "XAUXAT_MAIN_PROFILE",
        "pt.exsoria.xauxat.notification-service": "XAUXAT_NSE_PROFILE",
        "pt.exsoria.xauxat.share": "XAUXAT_SHARE_PROFILE",
    }
    found = set()
    configurations = re.findall(
        r"isa = XCBuildConfiguration;.*?buildSettings = \{(.*?)\n\s*\};\s*name = (\w+);",
        project, re.DOTALL,
    )
    for settings, name in configurations:
        profiles = re.findall(r"^\s*PROVISIONING_PROFILE_SPECIFIER\s*=\s*(.*?);\s*$", settings, re.MULTILINE)
        if len(profiles) > 1:
            raise ValueError("duplicate provisioning profile setting can override manual signing")
        bundle = re.search(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*"?([^";\s]+)"?;', settings)
        if name == "Release" and bundle and bundle[1] in expected:
            required = '"$(' + expected[bundle[1]] + ')"'
            if profiles != [required]:
                raise ValueError(f"Release profile setting is missing or overridden for {bundle[1]}")
            found.add(bundle[1])
    if found != set(expected):
        raise ValueError("Release manual signing settings must cover the app, NSE and share extension")


def verify_source():
    verify_profile_settings((ROOT / "apps/ios/SimpleX.xcodeproj/project.pbxproj").read_text())
    config = (ROOT / "apps/ios/Release.xcconfig").read_text()
    setting = re.search(r"^XAUXAT_NTF_SERVER_B64\s*=\s*(\S+)", config, re.MULTILINE)
    if setting is None:
        raise ValueError("Release notification server is not configured")
    address = validate_server(setting[1])
    entitlements = read_plist(ROOT / "apps/ios/SimpleX NSE/SimpleX NSE.entitlements")
    if entitlements.get(FILTERING) is not True:
        raise ValueError("NSE source entitlement must enable notification filtering")
    service = (ROOT / "apps/ios/SimpleX NSE/NotificationService.swift").read_text()
    if not re.search(r"^private let xauXatNotificationFilteringEnabled = true\s*$", service, re.MULTILINE):
        raise ValueError("NSE filtering code and entitlement must be enabled together")
    print(f"Release notification configuration verified: {address}")


def signed_entitlements(bundle):
    result = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", str(bundle)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
    )
    return plistlib.loads(result.stdout)


def verify_app(app, require_configured, signed, production):
    nse = app / "PlugIns/SimpleX NSE.appex"
    share = app / "PlugIns/SimpleX SE.appex"
    bundles = (app, nse, share)
    settings = [read_plist(bundle / "Info.plist").get(SERVER_KEY, "") for bundle in bundles]
    if len(set(settings)) != 1:
        raise ValueError("main app, NSE and share extension use different notification servers")
    if require_configured or settings[0]:
        validate_server(settings[0])
    if signed:
        main_entitlements = signed_entitlements(app)
        nse_entitlements = signed_entitlements(nse)
        if nse_entitlements.get(FILTERING) is not True:
            raise ValueError("signed NSE is missing its filtering entitlement")
        result = subprocess.run(
            ["security", "cms", "-D", "-i", str(nse / "embedded.mobileprovision")],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
        )
        profile = plistlib.loads(result.stdout)
        if profile.get("Entitlements", {}).get(FILTERING) is not True:
            raise ValueError("NSE provisioning profile does not grant notification filtering")
        if production and main_entitlements.get("aps-environment") != "production":
            raise ValueError("exported main app does not use production APNs")
    print("Built app notification settings verified" + ("; signed NSE filtering and profile verified." if signed else "."))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--require-configured", action="store_true")
    parser.add_argument("--signed", action="store_true")
    parser.add_argument("--production", action="store_true")
    args = parser.parse_args()
    if (args.signed or args.production or args.require_configured) and args.app is None:
        parser.error("bundle verification options require --app")
    if args.production and not args.signed:
        parser.error("--production requires --signed")
    verify_source()
    if args.app is not None:
        verify_app(args.app, args.require_configured, args.signed, args.production)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        print(f"Notification configuration verification failed: {error}", file=sys.stderr)
        sys.exit(1)
