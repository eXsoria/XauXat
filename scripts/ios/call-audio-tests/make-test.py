"""Run both production microphone-format queries against native audio nodes."""
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
(out / "Current.swift").write_text(template.replace("BUSES", ", ".join(queries)), encoding="utf-8")
# The regression is sensitive to the previous invalid bus at either call site.
(out / "InvalidBus.swift").write_text(template.replace("BUSES", "1"), encoding="utf-8")
