import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("testflight", Path(__file__).with_name("testflight-status.py"))
tf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tf)


class TestFlightTests(unittest.TestCase):
    def test_es256_positive_integer_padding(self):
        r, s = bytes([128]) + bytes(31), bytes([1]) + bytes(31)
        body = b"\x02\x21\x00" + r + b"\x02\x20" + s
        self.assertEqual(tf.raw_signature(b"\x30" + bytes([len(body)]) + body), r + s)

    def test_invalid_signature_rejected(self):
        for value in [b"bad", b"\x30\x04\x02\x01\xff\x00", b"\x30\x04\x02\x01\x01\x00"]:
            with self.assertRaises((ValueError, IndexError)):
                tf.raw_signature(value)

    def test_preflight_rejects_existing_or_older_numbers(self):
        def api(path):
            return {"data": [{"id": tf.APP}]} if path.startswith("v1/apps?") else {"data": [{"attributes": {"version": "24"}}]}
        for number in [23, 24]:
            with self.assertRaises(RuntimeError):
                tf.preflight(api, number)
        self.assertEqual(tf.preflight(api, 25)["previous_build_number"], 24)

    def test_invalid_processing_never_publishes(self):
        def api(path):
            return {"data": [{"attributes": {"processingState": "INVALID"}}]}
        with self.assertRaisesRegex(RuntimeError, "processing failed"):
            tf.wait_ready(api, 25)

    def test_empty_processing_result_has_bounded_wait(self):
        with self.assertRaisesRegex(RuntimeError, "processing still pending"):
            tf.wait_ready(lambda path: {"data": []}, 25, timeout=0)

    def publication_api(self, testers=1, internal=True):
        mutations, localizations, linked = [], [], []
        def api(path, method="GET", data=None):
            if method != "GET":
                mutations.append((path, method, copy.deepcopy(data)))
                if path == "v1/betaBuildLocalizations":
                    localizations.append({"id": "notes", "attributes": data["data"]["attributes"]})
                elif path.endswith("relationships/builds"):
                    linked.extend(data["data"])
                return {}
            if path.endswith("preReleaseVersion"):
                return {"data": {"attributes": {"platform": "IOS", "version": "0.0.1"}}}
            if path.endswith("/betaGroups"):
                return {"data": [{"id": tf.INTERNAL, "attributes": {"name": "XauXat Internal", "isInternalGroup": internal}}]}
            if "betaTesters" in path:
                return {"data": [{}] * testers, "links": {"next": None}}
            if path.endswith("betaBuildLocalizations"):
                return {"data": localizations}
            if path.endswith("relationships/builds"):
                return {"data": linked}
            if path.endswith("buildBetaDetail"):
                return {"data": {"attributes": {"internalBuildState": "IN_BETA_TESTING"}}}
            raise AssertionError(path)
        return api, mutations

    def test_publish_verifies_notes_and_only_existing_internal_group(self):
        api, mutations = self.publication_api()
        result = tf.publish_internal(api, {"id": "build25", "attributes": {"version": "25", "usesNonExemptEncryption": False}}, "Test contacts and audio")
        self.assertEqual(result["internal_build_state"], "IN_BETA_TESTING")
        self.assertEqual(len(mutations), 2)
        self.assertEqual(mutations[1][0], "v1/betaGroups/" + tf.INTERNAL + "/relationships/builds")
        self.assertNotIn("email", str(result))

    def test_group_change_rejected_before_any_mutation(self):
        for testers, internal in [(2, True), (0, True), (1, False)]:
            api, mutations = self.publication_api(testers, internal)
            with self.assertRaises(RuntimeError):
                tf.publish_internal(api, {"id": "build25", "attributes": {"usesNonExemptEncryption": False}}, "Notes")
            self.assertEqual(mutations, [])


if __name__ == "__main__":
    unittest.main()
