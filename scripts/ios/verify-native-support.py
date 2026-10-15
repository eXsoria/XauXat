"""Check the shipped support destination and prevent reintroducing an HTTP report path."""
import base64
import plistlib
import re
from pathlib import Path

root = Path(__file__).resolve().parents[2]
addresses = []
for config in ("Debug", "Release"):
    content = (root / f"apps/ios/{config}.xcconfig").read_text(encoding="utf-8")
    encoded = re.search(r"^XAUXAT_SUPPORT_CONTACT_B64 = (\S+)$", content, re.M)
    assert encoded, f"Missing native support address in {config}"
    address = base64.b64decode(encoded[1], validate=True).decode()
    assert re.fullmatch(r"https://smp[0-9]+\.simplex\.im/a#[A-Za-z0-9_-]{43}", address)
    addresses.append(address)
assert addresses[0] == addresses[1], "Builds must use the same official support profile"
info = plistlib.loads((root / "apps/ios/SimpleX--iOS--Info.plist").read_bytes())
assert info["XauXatSupportContactB64"] == "$(XAUXAT_SUPPORT_CONTACT_B64)"
client = (root / "apps/ios/Shared/Views/UserSettings/XauXatSupportClient.swift").read_text()
assert "planAndConnect(contactAddress, theme: theme, dismiss: true)" in client
for forbidden in ("URLSession", "URLRequest", "api/v1/tickets", "UIApplication.shared.open", "UIPasteboard"):
    assert forbidden not in client, f"Support must use native chat: {forbidden}"
# No transcript or recipient identity from the reported chat crosses this boundary.
share = (root / "apps/ios/Shared/Views/Helpers/ShareSheet.swift").read_text()
boundary = share[share.index("struct XauXatSafetyReport:"):share.index("func getTopViewController()")]
for forbidden in ("selectedText", "contactName", "ChatItem", "XauXatSupportRequest"):
    assert forbidden not in boundary
unit = (root / "services/support-chat/xauxat-support-chat.service").read_text()
for required in ("User=xauxat-support", "MemoryMax=384M", "UMask=0077", "ProtectSystem=strict"):
    assert required in unit
print("Native support configuration and privacy boundaries verified.")
