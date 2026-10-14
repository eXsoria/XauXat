#!/usr/bin/env python3
"""Regression checks for endpoint and signed filtering verification."""

import base64
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("notification_configuration", Path(__file__).with_name("verify-notification-configuration.py"))
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)
ADDRESS = "ntf://Q__L3KOO1Oqe7_3Cgg0q6mwpVE6Rd2FAAGdGWZegmjQ=@nft.exsoria.pt:8443"
ENCODED = base64.b64encode(ADDRESS.encode()).decode()


class NotificationConfigurationTests(unittest.TestCase):
    def profile_fixture(self):
        return "\n".join(
            'isa = XCBuildConfiguration;\nbuildSettings = {\n'
            f'PRODUCT_BUNDLE_IDENTIFIER = "{bundle}";\n'
            f'PROVISIONING_PROFILE_SPECIFIER = "$({variable})";\n'
            '};\nname = Release;'
            for bundle, variable in (
                ("pt.exsoria.xauxat", "XAUXAT_MAIN_PROFILE"),
                ("pt.exsoria.xauxat.notification-service", "XAUXAT_NSE_PROFILE"),
                ("pt.exsoria.xauxat.share", "XAUXAT_SHARE_PROFILE"),
            )
        )

    def test_distinct_release_profiles(self):
        config.verify_profile_settings(self.profile_fixture())

    def test_empty_duplicate_nse_profile_rejected(self):
        project = self.profile_fixture().replace(
            'PROVISIONING_PROFILE_SPECIFIER = "$(XAUXAT_NSE_PROFILE)";',
            'PROVISIONING_PROFILE_SPECIFIER = "$(XAUXAT_NSE_PROFILE)";\nPROVISIONING_PROFILE_SPECIFIER = "";',
        )
        with self.assertRaisesRegex(ValueError, "duplicate"):
            config.verify_profile_settings(project)

    def test_wrong_extension_profile_rejected(self):
        project = self.profile_fixture().replace("XAUXAT_NSE_PROFILE", "XAUXAT_MAIN_PROFILE")
        with self.assertRaisesRegex(ValueError, "missing or overridden"):
            config.verify_profile_settings(project)

    def test_missing_extension_profile_rejected(self):
        project = self.profile_fixture().replace('PROVISIONING_PROFILE_SPECIFIER = "$(XAUXAT_SHARE_PROFILE)";', '')
        with self.assertRaises(ValueError):
            config.verify_profile_settings(project)

    def test_pinned_public_endpoint(self):
        self.assertEqual(config.validate_server(ENCODED), ADDRESS)

    def test_invalid_endpoints(self):
        values = ("", "$(XAUXAT_NTF_SERVER_B64)", "!invalid!", None)
        addresses = (
            ADDRESS.replace("ntf://", "https://"),
            ADDRESS.replace("Q__L3KOO1Oqe7_3Cgg0q6mwpVE6Rd2FAAGdGWZegmjQ=", "short"),
            ADDRESS.replace(":8443", ":0"),
            ADDRESS.replace(":8443", ":65536"),
            ADDRESS.replace(":8443", ":invalid"),
            ADDRESS + "/unexpected",
            ADDRESS + "?token=unexpected",
            ADDRESS.replace("nft.exsoria.pt", "nft. exsoria.pt"),
        )
        for value in (*values, *(base64.b64encode(address.encode()).decode() for address in addresses)):
            with self.subTest(value=value), self.assertRaises(ValueError):
                config.validate_server(value)

    def make_app(self, root, endpoint=ENCODED):
        app = root / "XauXat.app"
        for bundle in (app, app / "PlugIns/SimpleX NSE.appex", app / "PlugIns/SimpleX SE.appex"):
            bundle.mkdir(parents=True, exist_ok=True)
            (bundle / "Info.plist").write_bytes(plistlib.dumps({config.SERVER_KEY: endpoint}))
        return app

    def test_configured_bundle_set(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            config.verify_app(app, True, False, False)

    def test_empty_debug_allowed_but_distribution_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory), "")
            config.verify_app(app, False, False, False)
            with self.assertRaises(ValueError):
                config.verify_app(app, True, False, False)

    def test_mismatched_extension_endpoint_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            (app / "PlugIns/SimpleX NSE.appex/Info.plist").write_bytes(plistlib.dumps({config.SERVER_KEY: ""}))
            with self.assertRaises(ValueError):
                config.verify_app(app, True, False, False)

    def verify_signed_fixture(self, nse_filtering=True, profile_filtering=True, apns="production"):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            profile = plistlib.dumps({"Entitlements": {config.FILTERING: profile_filtering}})
            with patch.object(config, "signed_entitlements", side_effect=[{"aps-environment": apns}, {config.FILTERING: nse_filtering}]), patch.object(config.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout=profile)):
                config.verify_app(app, True, True, True)

    def test_signed_distribution_contract(self):
        self.verify_signed_fixture()

    def test_missing_signed_filtering_rejected(self):
        with self.assertRaises(ValueError):
            self.verify_signed_fixture(nse_filtering=False)

    def test_stale_profile_without_filtering_rejected(self):
        with self.assertRaises(ValueError):
            self.verify_signed_fixture(profile_filtering=False)

    def test_sandbox_export_rejected(self):
        with self.assertRaises(ValueError):
            self.verify_signed_fixture(apns="development")


if __name__ == "__main__":
    unittest.main()
