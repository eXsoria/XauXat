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
    @EnvironmentObject var chatModel: ChatModel
    @EnvironmentObject var theme: AppTheme
    var recordingFileName: String
    @Binding var recordingTime: TimeInterval?
    @Binding var recordingState: VoiceMessageRecordingState
    @Binding var maskingState: VoiceMaskingState
    let applyVoiceMask: (() -> Void)
    let cancelVoiceMessage: ((String) -> Void)
    let cancelEnabled: Bool

    @Binding var stopPlayback: Bool // value is not taken into account, only the fact it switches
    @State private var audioPlayer: AudioPlayer?
    @State private var playbackState: VoiceMessagePlaybackState = .noPlayback
    @State private var playbackTime: TimeInterval?
    @State private var startingPlayback: Bool = false

    private var previewHeight: CGFloat {
        recordingState == .finished && maskingState != .unavailable ? 94 : 55
    }

    var body: some View {
        VStack(spacing: 0) {
            if recordingState != .finished {
                recordingMode()
            } else {
                playbackMode()
                maskingMode()
            }
        }
        .padding(.vertical, 1)
        .frame(height: previewHeight)
        .background(theme.appColors.sentMessage)
        .frame(minHeight: 54)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func maskingMode() -> some View {
        switch maskingState {
        case .unavailable:
            EmptyView()
        case .available:
            Button(action: applyVoiceMask) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.badge.shield.lefthalf.filled")
                    Text("Mask voice")
                        .fontWeight(.medium)
                    Spacer()
                    Text(XauXatVoiceMask.presetName)
                        .foregroundColor(theme.colors.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.colors.primary)
            .accessibilityHint("Applies the local Veil voice transformation. The original recording is removed.")
        case .processing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Masking voice on this device…")
                    .foregroundColor(theme.colors.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
        case .applied:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                Text("Voice masked")
                    .fontWeight(.medium)
                Spacer()
                Text(XauXatVoiceMask.presetName)
                    .foregroundColor(theme.colors.secondary)
            }
            .foregroundColor(theme.colors.primary)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .accessibilityElement(children: .combine)
        }
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
        ZStack {
            HStack(alignment: .center, spacing: 8) {
                switch playbackState {
                case .noPlayback:
                    Button {
                        startPlayback()
                    } label: {
                        playPauseIcon("play.fill", theme.colors.primary)
                    }
                    Text(voiceMessageTime_(recordingTime))
                case .playing:
                    Button {
                        audioPlayer?.pause()
                        playbackState = .paused
                    } label: {
                        playPauseIcon("pause.fill", theme.colors.primary)
                    }
                    Text(voiceMessageTime_(playbackTime))
                case .paused:
                    Button {
                        audioPlayer?.play()
                        playbackState = .playing
                    } label: {
                        playPauseIcon("play.fill", theme.colors.primary)
                    }
                    Text(voiceMessageTime_(playbackTime))
                }
                Spacer()
                if cancelEnabled {
                    cancelButton()
                }
            }
            .padding(.trailing, 12)
            .padding(.top, 4)

            if let recordingLength = recordingTime {
                GeometryReader { _ in
                    SliderBar(length: recordingLength, progress: $playbackTime, seek: { audioPlayer?.seek($0) })
                }
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
        .onChange(of: chatModel.stopPreviousRecPlay) { _ in
            if !startingPlayback {
                audioPlayer?.stop()
                playbackState = .noPlayback
                playbackTime = TimeInterval(0)
            } else {
                startingPlayback = false
            }
        }
    }

    private func playPauseIcon(_ image: String, _ color: Color) -> some View {
        Image(systemName: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 20, height: 20)
            .foregroundColor(color)
            .padding(.leading, 12)
    }

    private func cancelButton() -> some View {
        Button {
            audioPlayer?.stop()
            cancelVoiceMessage(recordingFileName)
        } label: {
            Image(systemName: "multiply")
        }
        .tint(theme.colors.primary)
    }

    struct SliderBar: View {
        @EnvironmentObject var theme: AppTheme
        var length: TimeInterval
        @Binding var progress: TimeInterval?
        var seek: (TimeInterval) -> Void

        var body: some View {
            Slider(value: Binding(get: { progress ?? TimeInterval(0) }, set: { seek($0) }), in: 0 ... length)
                .frame(maxWidth: .infinity)
                .frame(height: 4)
                .tint(theme.colors.primary)
        }
    }

    private struct ProgressBar: View {
        @EnvironmentObject var theme: AppTheme
        var length: TimeInterval
        @Binding var progress: TimeInterval?

        var body: some View {
            GeometryReader { geometry in
                ZStack {
                    Rectangle()
                        .fill(theme.colors.primary)
                        .frame(width: min(CGFloat((progress ?? TimeInterval(0)) / length) * geometry.size.width, geometry.size.width), height: 4)
                        .animation(.linear, value: progress)
                }
                .frame(height: 4)
            }
        }
    }

    private func startPlayback() {
        startingPlayback = true
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

struct ComposeVoiceView_Previews: PreviewProvider {
    static var previews: some View {
        ComposeVoiceView(
            recordingFileName: "voice.m4a",
            recordingTime: Binding.constant(TimeInterval(20)),
            recordingState: Binding.constant(VoiceMessageRecordingState.recording),
            maskingState: Binding.constant(VoiceMaskingState.available),
            applyVoiceMask: {},
            cancelVoiceMessage: { _ in },
            cancelEnabled: true,
            stopPlayback: Binding.constant(false)
        )
        .environmentObject(ChatModel())
    }
}
