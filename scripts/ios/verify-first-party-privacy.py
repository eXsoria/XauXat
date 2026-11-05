"""Verify the reviewed required-reason declarations in each built iOS bundle."""
from pathlib import Path
import plistlib
import sys

repo = Path(__file__).resolve().parents[2]
app = Path(sys.argv[1])
bundles = (
    (app, repo / "apps/ios/Shared"),
    (app / "Frameworks/SimpleXChat.framework", repo / "apps/ios/SimpleXChat"),
    (app / "PlugIns/SimpleX NSE.appex", repo / "apps/ios/SimpleX NSE"),
    (app / "PlugIns/SimpleX SE.appex", repo / "apps/ios/SimpleX SE"),
)
for bundle, source in bundles:
    with (source / "PrivacyInfo.xcprivacy").open("rb") as file:
        expected = plistlib.load(file)
    with (bundle / "PrivacyInfo.xcprivacy").open("rb") as file:
        actual = plistlib.load(file)
    if actual != expected:
        raise SystemExit("Required-reason API manifest differs from reviewed source: " + str(bundle))
    print("Verified required-reason API manifest: " + bundle.name)
