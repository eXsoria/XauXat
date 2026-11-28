"""Test microphone bus queries and the WebRTC playout format on native audio nodes."""
from pathlib import Path
import re
import sys

root, out = map(Path, sys.argv[1:])
source = (root / "apps/ios/Shared/Views/Call/XauXatRealtimeAudioDevice.swift").read_text(encoding="utf-8")
queries = re.findall(r"(?:audioEngine|engine)\.inputNode\.outputFormat\(forBus: (\d+)\)", source)
if len(queries) != 2:
    raise RuntimeError("Expected the initial capture and existing-engine format queries")
out.mkdir(parents=True, exist_ok=True)
template = '''import AVFoundation
import Foundation

let engine = AVAudioEngine()
let input = engine.inputNode
let buses: [AVAudioNodeBus] = [BUSES]
for bus in buses {
    // Validate against the framework's actual node topology before the query:
    // an invalid bus raises an Objective-C exception outside Swift do/catch.
    guard bus < input.numberOfOutputs else {
        fputs("Invalid microphone output bus \\(bus) / \\(input.numberOfOutputs)\\n", stderr)
        exit(1)
    }
    let format = input.outputFormat(forBus: bus)
    guard format.sampleRate.isFinite else { exit(1) }
}
print("Native microphone format checks passed: \\(buses.count)")
'''
# Exercise the production playout initializer on a real four-channel layout.
playout = re.search(r"let rtcPlayFormat = (AVAudioFormat\(.*?\)) else", source, re.S)
channels = re.search(r"    var xauxatWebRTCChannels: AVAudioChannelCount .*", source)
if not playout or not channels:
    raise RuntimeError("Missing production playout format")
output_test = """
extension AVAudioFormat {
CHANNELS
}
let quad = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Quadraphonic)!
let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: quad)
let playback = PLAYOUT
precondition(outputFormat.channelCount == 4 && playback?.channelCount == 2)
print("Quadraphonic route uses stereo WebRTC playout.")
""".replace("CHANNELS", channels[0]).replace("PLAYOUT", playout[1])
(out / "Current.swift").write_text(template.replace("BUSES", ", ".join(queries)) + output_test, encoding="utf-8")
# The regression is sensitive to the previous invalid bus at either call site.
(out / "InvalidBus.swift").write_text(template.replace("BUSES", "1"), encoding="utf-8")
