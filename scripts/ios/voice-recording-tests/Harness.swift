import SwiftUI
import AVFoundation
import OSLog

let MAX_VOICE_MESSAGE_LENGTH: TimeInterval = 6
let logger = Logger(subsystem: "pt.exsoria.voice-harness", category: "recording")
func durationText(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }
func getAppFilePath(_ name: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(name) }
func generateNewFileName(_ prefix: String, _ suffix: String) -> String { prefix + "." + suffix }
func removeFile(_ name: String) { try? FileManager.default.removeItem(at: getAppFilePath(name)) }
func fileSize(_ url: URL) -> Int64? { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) }
struct CryptoFile {
    var filePath: String
    var cryptoArgs: Int? = nil
    static func plain(_ name: String) -> Self { Self(filePath: name) }
}
func readCryptoFile(path: String, cryptoArgs: Int) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
enum AppDelegate {
    static func keepScreenOn(_ value: Bool) { UIApplication.shared.isIdleTimerDisabled = value }
}
enum VoiceMessageRecordingState { case noRecording, recording, finished }
enum VoiceMaskingState: Equatable { case unavailable, available, processing, applied(XauXatVoiceMaskPreset) }
enum XauXatVoiceMaskPreset: String { case veil; var name: String { "Veil" }; static let defaultPreferenceKey = "voice-mask" }
enum Feature { case voice, advancedVoiceMasking }
class XauXatPlusEntitlements: ObservableObject {
    static let shared = XauXatPlusEntitlements()
    func isAuthorized(for feature: Feature) -> Bool { false }
}
class ChatModel: ObservableObject { @Published var stopPreviousRecPlay: URL? }
struct ChatInfo {
    var sendMsgEnabled = true
    func featureEnabled(_ feature: Feature) -> Bool { true }
}
struct Chat { var chatInfo = ChatInfo() }
enum ComposePreview { case noPreview, voicePreview(recordingFileName: String, duration: Int) }
struct ComposeState {
    var preview = ComposePreview.noPreview
    var voiceMessageRecordingState = VoiceMessageRecordingState.noRecording
    var voiceMaskingState = VoiceMaskingState.unavailable
    var inProgress = false
    var noPreview: Bool { if case .noPreview = preview { return true }; return false }
    var voiceMessageRecordingFileName: String? { if case let .voicePreview(name, _) = preview { return name }; return nil }
    func copy(preview: ComposePreview? = nil, voiceMessageRecordingState: VoiceMessageRecordingState? = nil, voiceMaskingState: VoiceMaskingState? = nil) -> Self {
        var result = self
        if let preview { result.preview = preview }
        if let voiceMessageRecordingState { result.voiceMessageRecordingState = voiceMessageRecordingState }
        if let voiceMaskingState { result.voiceMaskingState = voiceMaskingState }
        return result
    }
}
struct ThemeColors { let primary = Color.accentColor; let secondary = Color.secondary; let sentMessage = Color(uiColor: .secondarySystemBackground) }
class AppTheme: ObservableObject { let colors = ThemeColors(); let appColors = ThemeColors() }
class AlertManager {
    static let shared = AlertManager()
    func showAlert(_ alert: Alert) {}
    func showAlertMsg(title: LocalizedStringKey, message: String) {}
}
struct XauXatVoiceMaskPickerView: View {
    let recordingURL: URL
    let initialPreset: XauXatVoiceMaskPreset
    let onApply: (XauXatVoiceMaskPreset, Bool) -> Void
    var body: some View { Text("Mask picker") }
}

@main struct VoiceHarness: App {
    @StateObject var chatModel = ChatModel()
    @StateObject var theme = AppTheme()
    var body: some Scene {
        WindowGroup {
            HarnessView()
                .environmentObject(chatModel)
                .environmentObject(theme)
                .environmentObject(XauXatPlusEntitlements.shared)
                .environment(\.sizeCategory, CommandLine.arguments.contains("large-text") ? .accessibilityExtraExtraExtraLarge : .large)
                .preferredColorScheme(CommandLine.arguments.contains("dark") ? .dark : .light)
        }
    }
}

struct HarnessView: View {
    @EnvironmentObject var chatModel: ChatModel
    @State var chat = Chat()
    @State var composeState = ComposeState()
    @State var voiceInteraction = VoiceRecordingInteraction()
    @State var audioRecorder: AudioRecorder?
    @State var voiceMessageRecordingTime: TimeInterval?
    @State var voiceRecordingLevels: [CGFloat] = []
    @State var voiceRecordingViewVisible = true
    @State var stopPlayback = false
    @State var sent = 0
    @State var validDuration: TimeInterval = 0
    @Environment(\.scenePhase) var scenePhase

    var body: some View {
        VStack(spacing: 16) {
            Text("Voice messages").font(.title2)
            Text("Sent \(sent)")
            Text("Phase \(String(describing: voiceInteraction.phase))").accessibilityIdentifier("voice.phase")
            Text("Duration \(String(format: "%.2f", voiceMessageRecordingTime ?? 0))").accessibilityIdentifier("voice.duration")
            Text("Playable \(String(format: "%.2f", validDuration))").accessibilityIdentifier("voice.playable")
            Spacer()
            if composeState.voiceMessageRecordingState == .finished, let name = composeState.voiceMessageRecordingFileName {
                ComposeVoiceView(recordingFileName: name, recordingTime: $voiceMessageRecordingTime, recordingState: $composeState.voiceMessageRecordingState, maskingState: $composeState.voiceMaskingState, recordingLevels: voiceRecordingLevels, resumeRecording: audioRecorder == nil ? nil : resumeVoiceMessageRecording, applyVoiceMask: { _, _ in }, cancelVoiceMessage: { _ in discardVoiceMessageRecording() }, cancelEnabled: true, stopPlayback: $stopPlayback)
            }
            HStack(spacing: 0) {
                if voiceInteraction.active {
                    VoiceRecordingStatus(interaction: voiceInteraction, time: voiceMessageRecordingTime ?? 0, levels: voiceRecordingLevels, color: .accentColor, deleteRecording: discardVoiceMessageRecording)
                } else {
                    Text(composeState.noPreview ? "Message" : "Voice message…").foregroundColor(.secondary)
                    Spacer()
                }
                if composeState.noPreview || voiceInteraction.active {
                    VoiceRecordingButton(interaction: voiceInteraction, color: .accentColor, begin: beginVoiceMessageRecording, move: moveVoiceMessageRecording, release: releaseVoiceMessageRecording, cancelTouch: cancelVoiceMessageTouch, pause: finishVoiceMessageRecording)
                } else {
                    Button {
                        audioRecorder?.stop()
                        audioRecorder = nil
                        if let name = composeState.voiceMessageRecordingFileName {
                            validDuration = (try? AVAudioPlayer(contentsOf: getAppFilePath(name)))?.duration ?? 0
                        }
                        sent += 1
                        discardVoiceMessageRecording()
                    } label: { Image(systemName: "arrow.up.circle.fill").font(.largeTitle).frame(width: 44, height: 44) }
                    .accessibilityIdentifier("voice.send")
                }
            }
            .padding(8)
            .frame(minHeight: 60)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        }
        .padding()
        .onChange(of: composeState.voiceMessageRecordingState) { state in
            if state == .finished, let name = composeState.voiceMessageRecordingFileName {
                validDuration = (try? AVAudioPlayer(contentsOf: getAppFilePath(name)))?.duration ?? 0
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { finishVoiceMessageRecording() }
        }
    }
}
