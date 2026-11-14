//
//  ComposeVoiceView.swift
//  SimpleX (iOS)
//
//  Created by JRoberts on 21.11.2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import SwiftUI
import SimpleXChat

enum VoiceMessagePlaybackState {
    case noPlayback
    case playing
    case paused
}

func voiceMessageTime(_ time: TimeInterval) -> String {
    durationText(Int(time))
}

func voiceMessageTime_(_ time: TimeInterval?) -> String {
    durationText(Int(time ?? 0))
}

struct ComposeVoiceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var chatModel: ChatModel
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject private var plusEntitlements: XauXatPlusEntitlements
    var recordingFileName: String
    @Binding var recordingTime: TimeInterval?
    @Binding var recordingState: VoiceMessageRecordingState
    @Binding var maskingState: VoiceMaskingState
    var recordingLevels: [CGFloat] = []
    var resumeRecording: (() -> Void)? = nil
    var listenOnce: Binding<Bool>? = nil
    var sendPausedRecording: (() -> Void)? = nil
    let applyVoiceMask: (XauXatVoiceMaskPreset, Bool) -> Void
    let cancelVoiceMessage: ((String) -> Void)
    let cancelEnabled: Bool

    @Binding var stopPlayback: Bool // value is not taken into account, only the fact it switches
    @State private var audioPlayer: AudioPlayer?
    @State private var playbackState: VoiceMessagePlaybackState = .noPlayback
    @State private var playbackTime: TimeInterval?
    @State private var showMaskPicker = false
    @ScaledMetric(relativeTo: .body) private var timeLabelSize: CGFloat = 17

    var body: some View {
        VStack(spacing: 0) {
            if recordingState != .finished {
                recordingMode()
                    .frame(height: 55)
            } else {
                if resumeRecording != nil {
                    Text("Paused")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(theme.colors.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.top, 4)
                }
                playbackMode()
                if resumeRecording == nil { maskingMode() }
            }
        }
        .padding(.vertical, 6)
        .background(xauXatChampagne(colorScheme).opacity(0.10))
        .tint(xauXatChampagne(colorScheme))
        .frame(minHeight: 54)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showMaskPicker) {
            XauXatVoiceMaskPickerView(
                recordingURL: getAppFilePath(recordingFileName),
                initialPreset: preferredPreset,
                onApply: applyVoiceMask
            )
        }
    }

    @ViewBuilder private func maskingMode() -> some View {
        switch maskingState {
        case .unavailable:
            EmptyView()
        case .available:
            Button { showMaskPicker = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.badge.shield.lefthalf.filled")
                    Text("Mask voice")
                        .fontWeight(.medium)
                    Spacer()
                    Text(preferredPreset.name)
                        .foregroundColor(theme.colors.secondary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(xauXatChampagne(colorScheme))
            .accessibilityHint("Opens local voice transformations and previews.")
        case .processing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Masking voice on this device…")
                    .foregroundColor(theme.colors.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
        case let .applied(preset):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                Text("Voice masked")
                    .fontWeight(.medium)
                Spacer()
                Text(preset.name)
                    .foregroundColor(theme.colors.secondary)
            }
            .foregroundColor(xauXatChampagne(colorScheme))
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .accessibilityElement(children: .combine)
        }
    }

    private var preferredPreset: XauXatVoiceMaskPreset {
        guard let rawValue = UserDefaults.standard.string(forKey: XauXatVoiceMaskPreset.defaultPreferenceKey),
              let preset = XauXatVoiceMaskPreset(rawValue: rawValue),
              !preset.requiresPlus || plusEntitlements.isAuthorized(for: .advancedVoiceMasking) else {
            return .veil
        }
        return preset
    }

    private func recordingMode() -> some View {
        ZStack {
            HStack(alignment: .center, spacing: 8) {
                playPauseIcon("play.fill", Color(uiColor: .tertiaryLabel))
                Text(voiceMessageTime_(recordingTime))
                Spacer()
                if cancelEnabled {
                    cancelButton()
                }
            }
            .padding(.trailing, 12)
            .padding(.top, 4)

            ProgressBar(length: MAX_VOICE_MESSAGE_LENGTH, progress: $recordingTime)
        }
    }

    private func playbackMode() -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                switch playbackState {
                case .noPlayback:
                    Button {
                        startPlayback()
                    } label: {
                        playPauseIcon("play.fill", xauXatChampagne(colorScheme))
                    }
                    .accessibilityLabel("Play recording")
                    .accessibilityIdentifier("voice.play")
                    timeLabel(recordingTime)
                case .playing:
                    Button {
                        audioPlayer?.pause()
                        playbackState = .paused
                    } label: {
                        playPauseIcon("pause.fill", xauXatChampagne(colorScheme))
                    }
                    .accessibilityLabel("Pause playback")
                    .accessibilityIdentifier("voice.play")
                    timeLabel(playbackTime)
                case .paused:
                    Button {
                        audioPlayer?.play()
                        playbackState = .playing
                    } label: {
                        playPauseIcon("play.fill", xauXatChampagne(colorScheme))
                    }
                    .accessibilityLabel("Play recording")
                    .accessibilityIdentifier("voice.play")
                    timeLabel(playbackTime)
                }
                VoiceRecordingWaveform(levels: recordingLevels)
                if let listenOnce, maskingState != .processing {
                    VoiceListenOnceButton(selection: listenOnce, color: xauXatChampagne(colorScheme))
                }
                if sendPausedRecording == nil {
                    if let resumeRecording { resumeButton(resumeRecording) }
                    if cancelEnabled { cancelButton() }
                }
            }
            .padding(.trailing, 8)
            .padding(.top, 4)

            if let recordingLength = recordingTime, recordingLength > 0 {
                SliderBar(length: recordingLength, progress: $playbackTime, seek: { audioPlayer?.seek($0) })
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .accessibilityLabel("Recording position")
            }
            if let resumeRecording, let sendPausedRecording {
                HStack(spacing: 8) {
                    if cancelEnabled { cancelButton() }
                    Spacer(minLength: 0)
                    resumeButton(resumeRecording)
                    Spacer(minLength: 0)
                    Button(action: sendPausedRecording) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 33))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Send recording")
                    .accessibilityIdentifier("voice.send")
                }
                .padding(.horizontal, 8)
            }
        }
        .onChange(of: stopPlayback) { _ in
            audioPlayer?.stop()
            playbackState = .noPlayback
            playbackTime = 0
        }
        .onDisappear {
            audioPlayer?.stop()
        }
        .onChange(of: chatModel.stopPreviousRecPlay) { source in
            if source != getAppFilePath(recordingFileName) {
                audioPlayer?.stop()
                playbackState = .noPlayback
                playbackTime = TimeInterval(0)
            }
        }
    }

    private func playPauseIcon(_ image: String, _ color: Color) -> some View {
        Image(systemName: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 20, height: 20)
            .foregroundColor(color)
            .frame(width: 44, height: 44)
    }

    private func timeLabel(_ time: TimeInterval?) -> some View {
        Text(voiceMessageTime_(time))
            .font(.system(size: min(timeLabelSize, 28), weight: .regular, design: .monospaced))
            .fixedSize()
    }

    private func resumeButton(_ resumeRecording: @escaping () -> Void) -> some View {
        Button {
            audioPlayer?.stop()
            playbackState = .noPlayback
            playbackTime = nil
            resumeRecording()
        } label: {
            Label("Resume", systemImage: "mic.fill")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
        }
        .accessibilityLabel("Resume recording")
        .accessibilityIdentifier("voice.resume")
    }

    private func cancelButton() -> some View {
        Button {
            audioPlayer?.stop()
            cancelVoiceMessage(recordingFileName)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 20))
                .frame(width: 44, height: 44)
        }
        .tint(xauXatChampagne(colorScheme))
        .accessibilityLabel("Delete recording")
        .accessibilityIdentifier("voice.delete")
    }

    struct SliderBar: View {
        @Environment(\.colorScheme) private var colorScheme
        var length: TimeInterval
        @Binding var progress: TimeInterval?
        var seek: (TimeInterval) -> Void

        var body: some View {
            Slider(value: Binding(get: { progress ?? TimeInterval(0) }, set: { seek($0) }), in: 0 ... length)
                .frame(maxWidth: .infinity)
                .frame(height: 4)
                .tint(xauXatChampagne(colorScheme))
        }
    }

    private struct ProgressBar: View {
        @Environment(\.colorScheme) private var colorScheme
        var length: TimeInterval
        @Binding var progress: TimeInterval?

        var body: some View {
            GeometryReader { geometry in
                ZStack {
                    Rectangle()
                        .fill(xauXatChampagne(colorScheme))
                        .frame(width: min(CGFloat((progress ?? TimeInterval(0)) / length) * geometry.size.width, geometry.size.width), height: 4)
                        .animation(.linear, value: progress)
                }
                .frame(height: 4)
            }
        }
    }

    private func startPlayback() {
        chatModel.stopPreviousRecPlay = getAppFilePath(recordingFileName)
        audioPlayer = AudioPlayer(
            onTimer: { playbackTime = $0 },
            onFinishPlayback: {
                playbackState = .noPlayback
                playbackTime = recordingTime // animate progress bar to the end
            }
        )
        audioPlayer?.start(fileSource: CryptoFile.plain(recordingFileName), at: playbackTime)
        playbackState = .playing
    }
}

private struct XauXatVoiceMaskPickerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var plusEntitlements: XauXatPlusEntitlements
    let recordingURL: URL
    let onApply: (XauXatVoiceMaskPreset, Bool) -> Void

    @State private var selected: XauXatVoiceMaskPreset
    @State private var rememberSelection = false
    @State private var previewing: XauXatVoiceMaskPreset?
    @State private var previewPlayer: AudioPlayer?
    @State private var previewOperation = UUID()
    @State private var showPlus = false
    @State private var errorMessage: String?

    init(
        recordingURL: URL,
        initialPreset: XauXatVoiceMaskPreset,
        onApply: @escaping (XauXatVoiceMaskPreset, Bool) -> Void
    ) {
        self.recordingURL = recordingURL
        self.onApply = onApply
        _selected = State(initialValue: initialPreset)
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    ForEach(XauXatVoiceMaskPreset.allCases) { preset in
                        presetRow(preset)
                    }
                } header: {
                    Text("Choose a voice")
                } footer: {
                    Text("Previews are rendered and played only on this device. Veil is included with Free.")
                }

                Section {
                    Toggle("Use this preset next time", isOn: $rememberSelection)
                } footer: {
                    Text("Your choice is saved only when this is enabled. Audio previews are never kept.")
                }
            }
            .navigationTitle("Voice masking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        guard canUse(selected) else {
                            showPlus = true
                            return
                        }
                        stopPreview()
                        onApply(selected, rememberSelection)
                        dismiss()
                    }
                }
            }
        }
        .tint(xauXatChampagne(colorScheme))
        .sheet(isPresented: $showPlus) {
            NavigationView {
                XauXatPlusView()
                    .navigationTitle("XauXat Plus")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showPlus = false }
                        }
                    }
            }
        }
        .alert("Unable to preview voice", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear { stopPreview() }
    }

    private func presetRow(_ preset: XauXatVoiceMaskPreset) -> some View {
        HStack(spacing: 12) {
            Button {
                guard canUse(preset) else {
                    showPlus = true
                    return
                }
                selected = preset
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(preset.name)
                            .foregroundColor(.primary)
                        if preset.requiresPlus {
                            Text("Plus")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Text(preset.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("voice.recording.preset.\(preset.rawValue)")

            if !canUse(preset) {
                Button { showPlus = true } label: {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Unlock \(preset.name) with XauXat Plus")
            } else {
                Button { preview(preset) } label: {
                    Image(systemName: previewing == preset ? "stop.fill" : "play.fill")
                        .foregroundColor(xauXatChampagne(colorScheme))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(previewing == preset ? "Stop preview" : "Preview \(preset.name)")
            }

            Image(systemName: selected == preset ? "checkmark.circle.fill" : "circle")
                .foregroundColor(selected == preset ? xauXatChampagne(colorScheme) : .secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 3)
    }

    private func canUse(_ preset: XauXatVoiceMaskPreset) -> Bool {
        !preset.requiresPlus || plusEntitlements.isAuthorized(for: .advancedVoiceMasking)
    }

    private func preview(_ preset: XauXatVoiceMaskPreset) {
        if previewing == preset {
            stopPreview()
            return
        }
        stopPreview()
        selected = preset
        let operation = UUID()
        previewOperation = operation
        previewing = preset
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try XauXatVoiceMask.previewData(from: recordingURL, preset: preset) }
            }.value
            guard previewOperation == operation else { return }
            switch result {
            case let .success(data):
                let player = AudioPlayer(onTimer: { _ in }, onFinishPlayback: {
                    if previewOperation == operation {
                        previewing = nil
                        previewPlayer = nil
                    }
                })
                previewPlayer = player
                player.start(data: data)
            case let .failure(error):
                previewing = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func stopPreview() {
        previewOperation = UUID()
        previewPlayer?.stop()
        previewPlayer = nil
        previewing = nil
    }
}

struct ComposeVoiceView_Previews: PreviewProvider {
    static var previews: some View {
        ComposeVoiceView(
            recordingFileName: "voice.m4a",
            recordingTime: Binding.constant(TimeInterval(20)),
            recordingState: Binding.constant(VoiceMessageRecordingState.recording),
            maskingState: Binding.constant(VoiceMaskingState.available),
            applyVoiceMask: { _, _ in },
            cancelVoiceMessage: { _ in },
            cancelEnabled: true,
            stopPlayback: Binding.constant(false)
        )
        .environmentObject(ChatModel())
        .environmentObject(XauXatPlusEntitlements.shared)
    }
}
