#!/usr/bin/env python3
"""Exercise the composer file lifecycle. Run with Python 3 on macOS with Xcode."""
import math
import struct
import subprocess
import tempfile
import wave
from pathlib import Path

root = Path(__file__).resolve().parents[2]
source = (root / "apps/ios/Shared/Views/Chat/ComposeMessage/ComposeView.swift").read_text()
fixture = (root / "scripts/ios/voice-recording-tests/SendRetry.swift").read_text()


def between(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


locked = between(source, "private func saveXauXatCodeLockedAudio(", "private func saveXauXatCodeLockedVideo(")
batch = between(source, "func send(_ msgs: [ComposedMessage]", "func forwardItems(")
sections = {
    "protected-source-cleanup": between(locked.split("guard let protectedFile = saveFile(", 1)[1], ") else { return nil }", "return protectedFile"),
    "prepare-voice-file": "func voiceCryptoFile(" + between(source, "func voiceCryptoFile(", "func send(_ reportReason:"),
    "failed-send-cleanup": "for msg in msgs {" + between(batch, "for msg in msgs {", "return []"),
    "voice-preview-branch": between(source, "case let .voicePreview(recordingFileName, duration):\n", "case let .filePreview(_, file):"),
}
for marker, production in sections.items():
    fixture = fixture.replace("// @production:" + marker, production)
assert "// @production:" not in fixture

with tempfile.TemporaryDirectory() as workspace:
    directory = Path(workspace)
    with wave.open(str(directory / "tone.wav"), "wb") as audio:
        audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        phase = 2 * math.pi * 440 / 16000
        audio.writeframes(b"".join(struct.pack("<h", int(500 * math.sin(i * phase))) for i in range(32000)))
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "tone.wav", "tone.m4a"], cwd=directory, check=True)
    (directory / "Retry.swift").write_text(fixture)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-suppress-warnings", "-module-cache-path",
                    str(directory / "modules"), "Retry.swift", "-o", "retry"], cwd=directory, check=True)
    subprocess.run(["./retry"], cwd=directory, check=True)
