// The transport and encryption adapters isolate ownership of real on-disk audio files.
import AVFAudio
import Foundation

struct CryptoFile {
  var filePath: String
  var cryptoArgs: Int? = nil
  static func plain(_ p: String) -> Self { Self(filePath: p) }
}
struct Defaults {
  let v: Bool
  func get() -> Bool { v }
}
final class State {
  var inProgress = true
  var hasDraft = true
  var voiceListenOnce = false
  let voiceMessageRecordingFileName: String? = "draft.m4a"
}
enum Msg { case voice(text: String, duration: Int) }
struct Recorder { func stop() {} }
enum AudioPlayer {
  static func hasPlayableVoiceMessage(at p: URL, declaredDuration: Double) -> Bool {
    ((try? AVAudioPlayer(contentsOf: p))?.duration ?? 0) >= declaredDuration - 0.1
  }
}
final class AlertManager {
  static let shared = AlertManager()
  func showAlertMsg(title: String, message: String) {}
}
enum XauXatCodeLockedEnvelope {
  enum Kind { case audio }
  static func fileWireText(kind: Kind) -> String { "" }
}
func getAppFilePath(_ n: String) -> URL {
  URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(n)
}
func removeFile(_ url: URL) { try? FileManager.default.removeItem(at: url) }
func removeFile(_ name: String) { removeFile(getAppFilePath(name)) }
func generateNewFileName(_ p: String, _ ext: String) -> String {
  "work-" + UUID().uuidString + "." + ext
}
func excludeFromSystemBackup(_ url: URL) -> Bool { true }
func encryptCryptoFile(fromPath: String, toPath: String) throws -> Int {
  try FileManager.default.copyItem(atPath: fromPath, toPath: toPath)
  return 1
}
let xauXatVoiceOncePrefix = "once"
struct Message { var fileSource: CryptoFile? }
func run(_ composeState: State, _ encrypt: Bool, _ protected: Bool, _ accepted: Bool) async -> Int?
{
  let recordingFileName = "draft.m4a"
  let duration = 2
  let codeLockCode: String? = protected ? "fixture" : nil
  let codeLockMaxAttempts: Int? = nil
  let codeLockDestroyOnExhaustion = false
  let msgText = ""
  let quoted: Int? = nil
  let ttl: Int? = nil
  let mentions: [String: Int] = [:]
  let sign = false
  let canSetVoiceListenOnce = true
  let privacyEncryptLocalFilesGroupDefault = Defaults(v: encrypt)
  let voiceDraftFileName = composeState.voiceMessageRecordingFileName
  var audioRecorder: Recorder? = nil
  var sent: Int? = nil
  var stopPlayback = false
  func saveXauXatCodeLockedAudio(
    recordingFileName: String, duration: Int, code: String, maxAttempts: Int?,
    destroyAfterMaxAttempts: Bool, caption: String
  ) async -> CryptoFile? {
    let source = getAppFilePath(recordingFileName)
    let dest = generateNewFileName("envelope", "xauxat")
    try! FileManager.default.copyItem(at: source, to: getAppFilePath(dest))
    // @production:protected-source-cleanup
    return .plain(dest)
  }
  // @production:prepare-voice-file
  func send(
    _ x: Msg, quoted: Int?, file: CryptoFile, ttl: Int?, mentions: [String: Int], sign: Bool
  ) async -> Int? {
    if accepted { return 1 }
    let msgs = [Message(fileSource: file)]
    // @production:failed-send-cleanup
    return nil
  }
  // @production:voice-preview-branch
  composeState.hasDraft = false
  composeState.inProgress = false
  return sent
}
@main struct Check {
  static func main() async throws {
    let bytes = try Data(contentsOf: getAppFilePath("tone.m4a"))
    var failures = 0
    for (label, enc, protected, once) in [
      ("plain", false, false, false), ("encrypted", true, false, false),
      ("once", false, false, true), ("onceEncrypted", true, false, true),
      ("codeLocked", true, true, false),
    ] {
      let state = State()
      state.voiceListenOnce = once
      let dir = FileManager.default.currentDirectoryPath
      let folder = UUID().uuidString
      try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
      precondition(FileManager.default.changeCurrentDirectoryPath(folder))
      try bytes.write(to: getAppFilePath("draft.m4a"))
      state.inProgress = true
      let first = await run(state, enc, protected, false)
      let kept = state.hasDraft && !state.inProgress && (try? Data(contentsOf: getAppFilePath("draft.m4a"))) == bytes
      let residue = try FileManager.default.contentsOfDirectory(atPath: ".").count
      var retry = false
      if kept {
        let second = await run(state, enc, protected, true)
        retry =
          second != nil && !state.hasDraft && (try? FileManager.default.contentsOfDirectory(atPath: ".").count) == 1
      }
      let ok = first == nil && kept && residue == 1 && retry
      print("\(label): preserved=\(kept) retry=\(retry) ok=\(ok)")
      if !ok { failures += 1 }
      precondition(FileManager.default.changeCurrentDirectoryPath(dir))
    }
    if failures != 0 { exit(1) }
  }
}
