"""Generate a host CallKit test with the app's dispatch, ownership and teardown branches."""
from pathlib import Path
import sys

source_directory, destination = map(Path, sys.argv[1:])
controller = (source_directory / "CallController.swift").read_text()
view = (source_directory / "ActiveCallView.swift").read_text()
manager = (source_directory / "CallManager.swift").read_text()
fixture = Path(__file__).with_name("TransportCloseTests.swift").read_text()


def method(source, signature):
    start = "    " + signature
    if source.count(start) != 1:
        raise ValueError(f"Expected one production method matching {signature}")
    offset = source.index(start)
    end = source.index("\n    }", offset) + len("\n    }")
    return source[offset:end]


controller_methods = [
    "func providerDidReset(",
    "func provider(_ provider: CXProvider, perform action: CXStartCallAction)",
    "func provider(_ provider: CXProvider, perform action: CXAnswerCallAction)",
    "func provider(_ provider: CXProvider, perform action: CXEndCallAction)",
    "func endCall(callUUID:",
    "func endCall(call: Call, completed:",
    "private func finishAnswer(",
]
if "func endCallAfterTransportClosed" in controller:
    controller_methods.append("func endCallAfterTransportClosed(")
manager_methods = ["func endCall(callUUID:", "func endCall(call:", "static func clearActiveCall("]
start = view.index('                if state.connectionState == "closed" {')
end = view.index("                Task {\n                    guard m.activeCall === call ||", start)
for token, source in [
    ("/* CALL_CONTROLLER */", "\n".join(method(controller, sig) for sig in controller_methods)),
    ("/* CALL_MANAGER */", "\n".join(method(manager, sig) for sig in manager_methods)),
    ("/* RTC_CLOSED */", view[start:end]),
]:
    if fixture.count(token) != 1:
        raise ValueError(f"Missing test insertion point: {token}")
    # Deliver scheduled callbacks explicitly, including the native end action
    # after the RTC callback returns. Keep the dispatched production bodies.
    source = source.replace("Task { @MainActor in", "enqueue { @MainActor [self] in")
    source = source.replace("Task {", "enqueue {")
    source = "\n".join(line for line in source.splitlines() if "logger." not in line)
    fixture = fixture.replace(token, source)
destination.write_text(fixture)
