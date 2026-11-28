"""Run the production relay-setting transaction against a controlled chat core."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "apps/ios/Shared/Model/SimpleXAPI.swift").read_text()
start = src.index("@MainActor\nfunc setXauXatMessageRelayMode(")
end = src.index("\nfunc apiSetNetworkInfo(", start)
production = src[start:end]
fixture = """
import Foundation
enum SMPProxyMode { case unknown, always, never, unprotected }
struct NetCfg: Equatable {
    var smpProxyMode: SMPProxyMode = .unknown
    var socks = 8111, retainedValue = 42
    var fallback = "allowProtected"
}
struct RuntimeError: Error { init(_ text: String) {} }
enum Session { case running, suspended, stopped, uninitialized, unlockRequired }
var session = Session.running, managed = true, published = 8111
var live = NetCfg(), puts = 0, reads = 0
var readFails = false, writeFails = false, failAfterWrite = false
enum Command { case apiGetNetworkConfig }
enum ResponseError: Error { case unexpected }
enum ChatResponse0 {
    case networkConfig(networkConfig: NetCfg), other
    var unexpected: Error { ResponseError.unexpected }
}
final class Preference {
    var value = SMPProxyMode.unknown, writes = 0
    func get() -> SMPProxyMode { value }
    func set(_ mode: SMPProxyMode) { value = mode; writes += 1 }
}
let networkSMPProxyModeGroupDefault = Preference()
func xauXatRecoverySessionState() -> Session { session }
func isXauXatManagedTorConfig(_ cfg: NetCfg) -> Bool { managed && cfg.socks != 1 }
func xauXatManagedTorConfig(_ cfg: NetCfg) -> NetCfg {
    var n = cfg; n.socks = published; return n
}
func chatSendCmdSync(_ op: Command, log: Bool) throws -> ChatResponse0 {
    precondition(!log); reads += 1
    if readFails { throw ResponseError.unexpected }; return .networkConfig(networkConfig:live)
}
func setNetworkConfig(_ cfg: NetCfg) throws {
    puts += 1
    if writeFails { throw ResponseError.unexpected }
    live = cfg
    if failAfterWrite { failAfterWrite = false; throw ResponseError.unexpected }
}
"""
checks = """
@main struct Run {
 @MainActor static func main() throws {
    func rejected(_ mode:SMPProxyMode) {
        do { try setXauXatMessageRelayMode(mode); fatalError("expected rejection") } catch {}
    }
    try setXauXatMessageRelayMode(.unknown)
    precondition(puts == 0 && reads == 0 && networkSMPProxyModeGroupDefault.writes == 0)
    live.fallback = "prohibit"; live.retainedValue = 89
    try setXauXatMessageRelayMode(.always)
    precondition(live.smpProxyMode == .always && live.fallback == "prohibit" && live.retainedValue == 89 && live.socks == 8111)
    precondition(puts == 1 && networkSMPProxyModeGroupDefault.value == .always)
    readFails = true; rejected(.never); readFails = false
    managed = false; rejected(.never); managed = true
    published = 3121; rejected(.never); published = 8111
    precondition(puts == 1 && networkSMPProxyModeGroupDefault.writes == 1)
    writeFails = true; rejected(.never); writeFails = false
    precondition(live.smpProxyMode == .always && networkSMPProxyModeGroupDefault.value == .always)
    failAfterWrite = true; rejected(.never)
    precondition(live.smpProxyMode == .always && networkSMPProxyModeGroupDefault.value == .always)
    live.smpProxyMode = .never; let before = puts
    try setXauXatMessageRelayMode(.never); precondition(puts == before)
    session = .unlockRequired; rejected(.unknown)
    for (state,mode) in [(Session.stopped,SMPProxyMode.unknown),(.suspended,.unprotected),(.uninitialized,.never)] {
        session = state; let previousReads = reads
        try setXauXatMessageRelayMode(mode)
        precondition(reads == previousReads && puts == before && networkSMPProxyModeGroupDefault.value == mode)
    }
    print("Passed active, deferred, privacy, idempotency and rollback cases")
 }
}
"""
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp)
    swift = path / "Test.swift"
    swift.write_text(fixture + production + checks)
    subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(path / "modules"), str(swift), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
