// Included only in the generated diagnostic app, never in XauXat targets.
import Foundation

private enum VoiceCITrace {
    static let lock = NSLock()
    static let url: URL = {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("voice-ci-\(ProcessInfo.processInfo.processIdentifier).jsonl")
    }()
}

func traceVoice(_ event: String, _ fields: [String: String] = [:]) {
    VoiceCITrace.lock.lock()
    defer { VoiceCITrace.lock.unlock() }
    var row = fields
    row["event"] = event
    row["uptime"] = String(ProcessInfo.processInfo.systemUptime)
    row["pid"] = String(ProcessInfo.processInfo.processIdentifier)
    let args = ProcessInfo.processInfo.arguments
    if let index = args.firstIndex(of: "--voice-ci-case"), args.indices.contains(index + 1) {
        row["case"] = args[index + 1]
    }
    guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
    data.append(10)
    if !FileManager.default.fileExists(atPath: VoiceCITrace.url.path) {
        FileManager.default.createFile(atPath: VoiceCITrace.url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: VoiceCITrace.url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
}

func traceVoiceError(_ event: String, _ error: Error) {
    let detail = error as NSError
    var fields = ["domain": detail.domain, "code": String(detail.code), "description": detail.localizedDescription]
    if let underlying = detail.userInfo[NSUnderlyingErrorKey] as? NSError {
        fields["underlyingDomain"] = underlying.domain
        fields["underlyingCode"] = String(underlying.code)
    }
    traceVoice(event, fields)
}

extension HarnessView {
    func traceVoiceState(_ event: String) {
        traceVoice(event, [
            "phase": String(describing: voiceInteraction.phase),
            "ready": String(voiceInteraction.ready),
            "request": voiceInteraction.requestID?.uuidString ?? "none",
            "duration": String(voiceMessageRecordingTime ?? -1),
            "recorderDuration": String(audioRecorder?.duration ?? -1),
            "recorderPresent": String(audioRecorder != nil),
            "preparationError": audioRecorder?.preparationError ?? "none",
            "recordingState": String(describing: composeState.voiceMessageRecordingState),
            "visible": String(voiceRecordingViewVisible),
            "scene": String(describing: scenePhase),
            "sending": String(expressionSending),
            "sendAllowed": String(chat.chatInfo.sendMsgEnabled),
            "voiceAllowed": String(chat.chatInfo.featureEnabled(.voice)),
            "composeBusy": String(composeState.inProgress),
            "noPreview": String(composeState.noPreview)
        ])
    }
}

extension AudioRecorder {
    func traceVoiceAudio(_ event: String) {
        traceVoice(event, [
            "recorder": String(describing: ObjectIdentifier(self)),
            "duration": String(duration), "offset": String(segmentOffset),
            "recording": String(audioRecorder?.isRecording == true),
            "currentTime": String(audioRecorder?.currentTime ?? -1),
            "cancelled": String(cancelled), "timer": String(recordingTimer != nil),
            "permission": String(describing: AVAudioSession.sharedInstance().recordPermission),
            "ownsSession": String(ownsAudioSession), "preparationError": preparationError ?? "none"
        ])
    }
}
