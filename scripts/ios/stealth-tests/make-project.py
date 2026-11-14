"""Build the production effect menus and LLVC renderer without chat networking.

Only call transport, entitlements, and preview playback are fixture adapters.
The model, voice-mask selection, effect menus, and file renderer are production.
"""
from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import sys

root, out = map(Path, sys.argv[1:])
fixtures = root / "scripts/ios/stealth-tests"
subprocess.run([sys.executable, str(root / "scripts/ios/voice-recording-tests/make-project.py"), str(root), str(out)], check=True)
for name in ("Harness.swift", "UITests.swift"):
    shutil.copyfile(fixtures / name, out / name)


def declaration(source, marker):
    start = source.index(marker)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


call = root / "apps/ios/Shared/Views/Call"
compose = root / "apps/ios/Shared/Views/Chat/ComposeMessage"
audio = (root / "apps/ios/Shared/Model/AudioRecPlay.swift").read_text(encoding="utf-8")
device = (call / "XauXatRealtimeAudioDevice.swift").read_text(encoding="utf-8")
picker = (compose / "ComposeVoiceView.swift").read_text(encoding="utf-8")
sources = ["import AVFoundation\nimport CoreML\nimport SwiftUI\nimport UIKit"]
sources += [declaration(audio, marker) for marker in (
    "enum XauXatVoiceMaskError:", "enum XauXatVoiceMaskPreset:",
    "func xauXatBoostMaskedVoice(", "struct XauXatVoiceMask {")]
sources += [declaration(device, marker) for marker in (
    "enum XauXatCallAmbience:", "@MainActor\nfinal class XauXatRealtimeVoiceMasking:",
    "final class XauXatCallAmbienceMixer {")]
sources += [(call / "XauXatLLVCCapture.swift").read_text(encoding="utf-8")]
sources += [declaration((call / "ActiveCallView.swift").read_text(encoding="utf-8"), "private struct XauXatRealtimeVoiceMaskingView:").replace("private struct", "struct", 1)]
sources += [declaration(picker, "private struct XauXatVoiceMaskPickerView:").replace("private struct", "struct", 1)]
settings = declaration((compose / "ComposeView.swift").read_text(encoding="utf-8"), "private var voiceNoteSettings:")
sources += ["extension HarnessView {\n" + settings.replace("private var", "var", 1) + "\n}"]
(out / "Editor.swift").write_text("\n".join(sources), encoding="utf-8")

# Reuse the existing small test-project layout, with actual Core ML resources.
project = out / "VoiceHarness.xcodeproj/project.pbxproj"
pbx = project.read_text(encoding="utf-8")
pbx = pbx.replace("name=Debug; buildSettings={", "name=Debug; buildSettings={SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG;")
lines = pbx.splitlines()
pbx = "\n".join(line.replace('SWIFT_OPTIMIZATION_LEVEL="-Onone";', 'SWIFT_OPTIMIZATION_LEVEL="-O";') if "name=Release;" in line else line for line in lines)
assets = out / "Ambience.xcassets"
assets.mkdir(exist_ok=True)
(assets / "Contents.json").write_text('{"info":{"author":"xcode","version":1}}', encoding="utf-8")
for name in ("CallAmbienceRain", "CallAmbienceTraffic"):
    shutil.copytree(root / f"apps/ios/Shared/Assets.xcassets/{name}.dataset", assets / f"{name}.dataset", dirs_exist_ok=True)
resources = [(assets, "folder.assetcatalog"), (call / "LLVC-LICENSE.txt", "text")]
if os.environ.get("STEALTH_TEST_MISSING_MODEL") != "1":
    resources += [(call / "XauXatLLVC.mlpackage", "folder.mlpackage")]
objects, refs, builds = [], [], []
for index, (path, kind) in enumerate(resources):
    ref, build = f"FB110000000000000000{index:04X}", f"FB220000000000000000{index:04X}"
    refs.append(ref)
    builds.append(build)
    objects += [f'{ref} = {{isa=PBXFileReference; lastKnownFileType={kind}; path={json.dumps(str(path.resolve()))}; sourceTree="<absolute>";}};', f"{build} = {{isa=PBXBuildFile; fileRef={ref};}};"]
phase = "FB3300000000000000000001"
objects += [f"{phase} = {{isa=PBXResourcesBuildPhase; buildActionMask=2147483647; files=({','.join(builds)}); runOnlyForDeploymentPostprocessing=0;}};"]
pbx = pbx.replace("objects={", "objects={\n" + "\n".join(objects), 1)
pbx = re.sub(r"(isa=PBXGroup; children=\()", lambda m: m[0] + ",".join(refs) + ",", pbx, count=1)
pbx = re.sub(r"(buildPhases=\([^)]*)(\); buildRules=\(\); dependencies=\(\); name=VoiceHarness;)", lambda m: m[1] + "," + phase + m[2], pbx, count=1)
project.write_text(pbx + "\n", encoding="utf-8")
