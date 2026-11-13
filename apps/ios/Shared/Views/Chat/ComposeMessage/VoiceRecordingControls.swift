import SwiftUI
import UIKit
import SimpleXChat

func xauXatChampagne(_ scheme: ColorScheme) -> Color {
    scheme == .dark
        ? Color(red: 222 / 255, green: 206 / 255, blue: 175 / 255)
        : Color(red: 146 / 255, green: 113 / 255, blue: 65 / 255)
}

let xauXatRecordingColor = Color(red: 208 / 255, green: 194 / 255, blue: 168 / 255)

func xauXatWaveformColor(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(white: 0.72) : Color(white: 0.30)
}

struct VoiceRecordingStatus: View {
    let interaction: VoiceRecordingInteraction
    let time: TimeInterval
    let levels: [CGFloat]
    let color: Color
    var deleteRecording: (() -> Void)? = nil
    var listenOnce: Binding<Bool>? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @ScaledMetric(relativeTo: .callout) private var timeLabelSize: CGFloat = 16

    var body: some View {
        HStack(spacing: 8) {
            if interaction.phase == .locked || interaction.phase == .finishing, let deleteRecording {
                Button(action: deleteRecording) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Delete recording")
                .accessibilityIdentifier("voice.cancel")
            } else {
              Circle()
                .fill(xauXatRecordingColor)
                .frame(width: 8, height: 8)
                .opacity(pulse && !reduceMotion ? 0.35 : 1)
                .accessibilityHidden(true)
            }
            Text(durationText(Int(time)))
                .monospacedDigit()
                .font(.system(size: min(timeLabelSize, 28), weight: .regular, design: .monospaced))
                .fixedSize()
                .accessibilityLabel("Recording duration")
                .accessibilityValue(durationText(Int(time)))
            if !interaction.ready {
                ProgressView().controlSize(.small)
                Text(interaction.phase == .finishing ? "Preparing audio…" : "Starting…").font(.caption).lineLimit(1)
            } else if interaction.phase == .holding {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                    Text("Slide to cancel")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .opacity(1 - interaction.cancelProgress * 0.6)
                .offset(x: -interaction.cancelProgress * 16)
                .frame(maxWidth: .infinity)
            } else {
                VoiceRecordingWaveform(levels: levels)
                if interaction.phase == .locked, let listenOnce {
                    VoiceListenOnceButton(selection: listenOnce, color: color)
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear {
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
            }
        }
    }
}

struct VoiceListenOnceButton: View {
    @Binding var selection: Bool
    let color: Color
    @AppStorage("xauxatVoiceOnceCompatibilityNotice") private var seenNotice = false
    @State private var showNotice = false

    var body: some View {
        Button {
            if !selection && !seenNotice {
                showNotice = true
            } else {
                selection.toggle()
            }
        } label: {
            Image(systemName: selection ? "1.circle.fill" : "1.circle")
                .font(.title2)
                .foregroundColor(selection ? color : .secondary)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Listen once")
        .accessibilityValue(selection ? "On" : "Off")
        .alert("Listen once", isPresented: $showNotice) {
            Button("Enable") {
                seenNotice = true
                selection = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Use with recipients on an updated XauXat iOS app. Older or other clients may play this voice message again.")
        }
    }
}

struct VoiceRecordingWaveform: View {
    let levels: [CGFloat]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let count = max(1, min(40, Int(geometry.size.width / 5)))
            let samples = Array(levels.suffix(count))
            HStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { index in
                    let sample = index < count - samples.count ? CGFloat(0) : samples[index - (count - samples.count)]
                    Capsule()
                        .fill(xauXatWaveformColor(colorScheme).opacity(sample > 0 ? 1 : 0.25))
                        .frame(width: 3, height: 3 + min(1, max(0, sample)) * 21)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
        }
        .frame(height: 26)
        .accessibilityHidden(true)
    }
}

struct VoiceRecordingButton: View {
    let interaction: VoiceRecordingInteraction
    let color: Color
    var disabled = false
    let begin: (Bool) -> Void
    let move: (Double, Double) -> Void
    let release: (VoiceRecordingTouchTiming) -> Void
    let cancelTouch: (VoiceRecordingTouchTiming) -> Void
    let pause: () -> Void

    var body: some View {
        ZStack {
            Circle()
                .fill(interaction.active ? xauXatRecordingColor : color)
            Image(systemName: interaction.phase == .locked ? "pause.fill" : "mic.fill")
                .font(.system(size: 21, weight: .medium))
                .foregroundColor(interaction.active ? Color(white: 0.20) : Color(uiColor: .systemBackground))
                .accessibilityHidden(true)
            VoiceRecordingTouchSurface(
                enabled: !disabled && interaction.phase != .finishing,
                label: interaction.phase == .locked ? NSLocalizedString("Pause recording", comment: "voice recording button") : NSLocalizedString("Record voice message", comment: "voice recording button"),
                hint: interaction.active ? "" : NSLocalizedString("Hold to record. Release when done. Slide left to cancel or up to lock. Double-tap to record hands-free.", comment: "voice recording accessibility hint"),
                touchDown: { interaction.phase == .locked ? pause() : begin(false) },
                move: move,
                release: release,
                cancel: cancelTouch,
                activate: { interaction.phase == .locked ? pause() : begin(true) }
            )
        }
        .frame(width: 44, height: 44)
        .opacity(disabled || interaction.phase == .finishing ? 0.4 : 1)
        .overlay(alignment: .bottom) {
            if interaction.phase == .holding {
                VStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                    Image(systemName: "chevron.up")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(color)
                .padding(.vertical, 14)
                .frame(width: 40)
                .background(.regularMaterial, in: Capsule())
                .offset(y: -56 + interaction.lockProgress * 12)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
        }
    }
}

// UIKit continues delivering the original touch outside the microphone bounds,
// including cancellation by the OS. Window coordinates survive composer layout.
private struct VoiceRecordingTouchSurface: UIViewRepresentable {
    let enabled: Bool
    let label: String
    let hint: String
    let touchDown: () -> Void
    let move: (Double, Double) -> Void
    let release: (VoiceRecordingTouchTiming) -> Void
    let cancel: (VoiceRecordingTouchTiming) -> Void
    let activate: () -> Void

    func makeUIView(context: Context) -> TouchView { TouchView() }

    func updateUIView(_ view: TouchView, context: Context) {
        view.actions = self
        view.isAccessibilityElement = true
        view.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
        view.accessibilityLabel = label
        view.accessibilityHint = hint
        view.accessibilityIdentifier = "voice.record"
    }

    final class TouchView: UIView {
        var actions: VoiceRecordingTouchSurface?
        private var origin: CGPoint?
        private var beganAt: TimeInterval?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard actions?.enabled == true, origin == nil, let touch = touches.first else { return }
            origin = touch.location(in: window)
            beganAt = touch.timestamp
            actions?.touchDown()
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let origin, let touch = touches.first else { return }
            let point = touch.location(in: window)
            actions?.move(Double(point.x - origin.x), Double(point.y - origin.y))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard origin != nil else { return }
            let timing = VoiceRecordingTouchTiming(
                beganAt: beganAt ?? .nan,
                endedAt: touches.first?.timestamp ?? .nan
            )
            origin = nil
            beganAt = nil
            actions?.release(timing)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            let timing = VoiceRecordingTouchTiming(
                beganAt: beganAt ?? .nan,
                endedAt: touches.first?.timestamp ?? .nan
            )
            origin = nil
            beganAt = nil
            actions?.cancel(timing)
        }

        override func accessibilityActivate() -> Bool {
            guard actions?.enabled == true else { return false }
            actions?.activate()
            return true
        }
    }
}
