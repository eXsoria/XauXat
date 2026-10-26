import SwiftUI
import AVFoundation
import OSLog

let MAX_VOICE_MESSAGE_LENGTH: TimeInterval = CommandLine.arguments.contains("short-limit") ? 6 : 120
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
class ChatModel: ObservableObject {
    @Published var stopPreviousRecPlay: URL?
    var draft: ComposeState?
    var draftChatId: String?
}
struct ChatInfo {
    let id = "chat"
    enum ShowEnableVoiceMessagesAlert { case other }
    var sendMsgEnabled = true
    func featureEnabled(_ feature: Feature) -> Bool { true }
    func groupChatScope() -> Int? { nil }
}
struct Chat { var chatInfo = ChatInfo(); var id: String { chatInfo.id } }
func draftChatId(_ id: String, _ scope: Int?) -> String { id }
enum ComposePreview { case noPreview, voicePreview(recordingFileName: String, duration: Int) }
enum ContextItem: Equatable { case noContextItem, reportedItem }
struct FixtureLiveMessage { var sentMsg: String? }
struct ComposeState {
    var preview = ComposePreview.noPreview
    var voiceMessageRecordingState = VoiceMessageRecordingState.noRecording
    var voiceMaskingState = VoiceMaskingState.unavailable
    var inProgress = false
    var message = ""
    var editing = false
    var forwarding = false
    var progressByTimeout = false
    var liveMessage: FixtureLiveMessage?
    var contextItem = ContextItem.noContextItem
    var placeholder: String { "Message" }
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
struct ThemeColors { let primary = Color.accentColor; let secondary = Color.secondary; let sentMessage = Color(uiColor: .secondarySystemBackground); let background = Color(uiColor: .systemBackground) }
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
    @State var finishingVoiceFileName: String?
    @State var voiceRecordingOwner = UUID()
    let saveLastDraft = true
    @State var stopPlayback = false
    @State var sent = 0
    @State var validDuration: TimeInterval = 0
    @State var selectedRange = NSRange()
    @State var keyboardVisible = false
    @State var keyboardHiddenDate = Date()
    @Environment(\.scenePhase) var scenePhase

    var body: some View {
        VStack(spacing: 16) {
            Text("Voice messages").font(.title2)
            VStack(spacing: 4) {
                Text("Sent \(sent)")
                Text("Phase \(String(describing: voiceInteraction.phase))").accessibilityIdentifier("voice.phase")
                Text("Duration \(String(format: "%.2f", voiceMessageRecordingTime ?? 0))").accessibilityIdentifier("voice.duration")
                Text("Playable \(String(format: "%.2f", validDuration))").accessibilityIdentifier("voice.playable")
                Text("Error \(audioRecorder?.preparationError ?? "none")")
                    .lineLimit(3)
                    .accessibilityIdentifier("voice.error")
            }
            .font(.system(size: 12))
            Spacer()
            if composeState.voiceMessageRecordingState == .finished, let name = composeState.voiceMessageRecordingFileName {
                ComposeVoiceView(recordingFileName: name, recordingTime: $voiceMessageRecordingTime, recordingState: $composeState.voiceMessageRecordingState, maskingState: $composeState.voiceMaskingState, recordingLevels: voiceRecordingLevels, resumeRecording: audioRecorder?.canResume == true ? resumeVoiceMessageRecording : nil, applyVoiceMask: { _, _ in }, cancelVoiceMessage: { _ in discardVoiceMessageRecording() }, cancelEnabled: true, stopPlayback: $stopPlayback)
            }
            SendMessageView(
                composeState: $composeState,
                selectedRange: $selectedRange,
                sendMessage: { _ in
                        audioRecorder?.stop()
                        audioRecorder = nil
                        if let name = composeState.voiceMessageRecordingFileName {
                            validDuration = (try? AVAudioPlayer(contentsOf: getAppFilePath(name)))?.duration ?? 0
                        }
                        sent += 1
                        discardVoiceMessageRecording()
                },
                sendLiveMessage: {},
                updateLiveMessage: {},
                voiceInteraction: voiceInteraction,
                voiceRecordingTime: voiceMessageRecordingTime ?? 0,
                voiceRecordingLevels: voiceRecordingLevels,
                startVoiceMessageRecording: beginVoiceMessageRecording,
                moveVoiceMessageRecording: moveVoiceMessageRecording,
                releaseVoiceMessageRecording: releaseVoiceMessageRecording,
                cancelVoiceMessageTouch: cancelVoiceMessageTouch,
                discardVoiceMessageRecording: discardVoiceMessageRecording,
                finishVoiceMessageRecording: finishVoiceMessageRecording,
                onMediaAdded: { _ in },
                keyboardVisible: $keyboardVisible,
                keyboardHiddenDate: $keyboardHiddenDate
            )
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
