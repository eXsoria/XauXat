"""Compile production recording controls, AAC recorder, preview and coordinator.
Only chat services and the test conversation are adapters.
"""
from pathlib import Path
import shutil
import sys

root, out = map(Path, sys.argv[1:])
fixtures = root / "scripts/ios/voice-recording-tests"
out.mkdir(parents=True, exist_ok=True)
for name in ("Harness.swift", "UITests.swift"):
    shutil.copyfile(fixtures / name, out / name)

compose = root / "apps/ios/Shared/Views/Chat/ComposeMessage"

def declaration(source, marker):
    start = source.index(marker)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]

sources = [(compose / name).read_text(encoding="utf-8") for name in ("VoiceRecordingInteraction.swift", "VoiceRecordingControls.swift")]
audio = (root / "apps/ios/Shared/Model/AudioRecPlay.swift").read_text(encoding="utf-8")
sources += ["import AVFoundation\nimport OSLog\n", declaration(audio, "@MainActor\nclass AudioRecorder:"), declaration(audio, "class AudioPlayer:")]
preview = (compose / "ComposeVoiceView.swift").read_text(encoding="utf-8")
sources += [preview[:preview.index("private struct XauXatVoiceMaskPickerView")].replace("import SimpleXChat", "")]
send = (compose / "SendMessageView.swift").read_text(encoding="utf-8")
send = send[:send.index("    private func deleteTextButton()")].replace("import SimpleXChat", "")
send = "\n".join(line for line in send.splitlines() if "@UserDefault" not in line)
adapters = r'''
    private func sendMessageButton() -> some View {
        Button { sendMessage(nil) } label: {
            Image(systemName: "arrow.up.circle.fill")
                .resizable()
                .frame(width: 29, height: 29)
                .frame(width: 44, height: 44)
        }
        .accessibilityIdentifier("voice.send")
    }
    private func sendToConnectButton(_ connect: @escaping () -> Void) -> some View { Button("Connect", action: connect) }
    private func voiceMessageNotAllowedButton() -> some View { Image(systemName: "mic") }
    private func startLiveMessageButton(send: @escaping () async -> Void, update: @escaping () async -> Void) -> some View {
        Image(systemName: "bolt.fill").resizable().scaledToFit().frame(width: 20, height: 20).frame(width: 29, height: 29).padding([.bottom, .horizontal], 4)
    }
    private func finishVoiceMessageRecordingButton() -> some View { Button("Pause") { finishVoiceMessageRecording?() } }
    private func cancelLiveMessageButton(cancel: @escaping () -> Void) -> some View { Button("Cancel", action: cancel) }
    private func deleteTextButton() -> some View { EmptyView() }
    private func updateFont(_ text: String) {}
}
'''
sources += [(fixtures / "ComposerAdapters.swift").read_text(encoding="utf-8"), send + adapters]
controller = (compose / "ComposeView.swift").read_text(encoding="utf-8")
methods = ["beginVoiceMessageRecording", "moveVoiceMessageRecording", "releaseVoiceMessageRecording", "cancelVoiceMessageTouch", "discardVoiceMessageRecording", "startVoiceMessageRecording", "bindVoiceRecorder", "finishVoiceMessageRecording", "resumeVoiceMessageRecording", "updateComposeVMRFinished", "cancelCurrentVoiceRecording", "cancelVoiceMessageRecording", "saveCurrentDraft"]
sources += ["extension HarnessView {\n" + "\n".join(declaration(controller, "private func " + name + "(").replace("private func", "func", 1) for name in methods) + "\n}"]
(out / "Editor.swift").write_text("\n".join(sources), encoding="utf-8")

project = out / "VoiceHarness.xcodeproj"
project.mkdir(exist_ok=True)
objects = []


def add(ident, body):
    assert all(not line.startswith(ident + " =") for line in objects), ident
    objects.append(f"{ident} = {{{body}}};")


add("P", "isa=PBXProject; buildConfigurationList=PC; compatibilityVersion=\"Xcode 14.0\"; developmentRegion=en; knownRegions=(en,Base); mainGroup=G; productRefGroup=PG; projectDirPath=\"\"; projectRoot=\"\"; targets=(A,T); attributes={LastUpgradeCheck=1600; TargetAttributes={T={TestTargetID=A;};};};")
add("G", "isa=PBXGroup; children=(F1,F2,F3,PG); sourceTree=\"<group>\";")
add("PG", "isa=PBXGroup; name=Products; children=(AP,TP); sourceTree=\"<group>\";")
for ident, path, kind in [("F1", "Harness.swift", "sourcecode.swift"), ("F2", "Editor.swift", "sourcecode.swift"), ("F3", "UITests.swift", "sourcecode.swift")]:
    add(ident, f'isa=PBXFileReference; lastKnownFileType={kind}; path={path}; sourceTree="<group>";')
add("AP", 'isa=PBXFileReference; explicitFileType=wrapper.application; path=VoiceHarness.app; sourceTree=BUILT_PRODUCTS_DIR;')
add("TP", 'isa=PBXFileReference; explicitFileType=wrapper.cfbundle; path=VoiceHarnessUITests.xctest; sourceTree=BUILT_PRODUCTS_DIR;')
for ident, ref in [("B1", "F1"), ("B2", "F2"), ("B3", "F3")]:
    add(ident, f"isa=PBXBuildFile; fileRef={ref};")
add("AS", "isa=PBXSourcesBuildPhase; buildActionMask=2147483647; files=(B1,B2); runOnlyForDeploymentPostprocessing=0;")
add("TS", "isa=PBXSourcesBuildPhase; buildActionMask=2147483647; files=(B3); runOnlyForDeploymentPostprocessing=0;")
add("A", 'isa=PBXNativeTarget; buildConfigurationList=AC; buildPhases=(AS); buildRules=(); dependencies=(); name=VoiceHarness; productName=VoiceHarness; productReference=AP; productType="com.apple.product-type.application";')
add("T", 'isa=PBXNativeTarget; buildConfigurationList=TC; buildPhases=(TS); buildRules=(); dependencies=(DEP); name=VoiceHarnessUITests; productName=VoiceHarnessUITests; productReference=TP; productType="com.apple.product-type.bundle.ui-testing";')
add("DEP", "isa=PBXTargetDependency; target=A; targetProxy=PX;")
add("PX", "isa=PBXContainerItemProxy; containerPortal=P; proxyType=1; remoteGlobalIDString=A; remoteInfo=VoiceHarness;")
common = 'SDKROOT=iphoneos; IPHONEOS_DEPLOYMENT_TARGET=15.0; SWIFT_VERSION=5.0; CODE_SIGNING_ALLOWED=NO; TARGETED_DEVICE_FAMILY=1; GENERATE_INFOPLIST_FILE=YES; CURRENT_PROJECT_VERSION=1; MARKETING_VERSION=1.0; PRODUCT_NAME="$(TARGET_NAME)";'
for prefix, settings in [("P", common), ("A", 'PRODUCT_BUNDLE_IDENTIFIER=pt.exsoria.voice-harness; INFOPLIST_KEY_NSMicrophoneUsageDescription="Record a test voice message"; INFOPLIST_KEY_UILaunchScreen_Generation=YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation=YES;'), ("T", 'PRODUCT_BUNDLE_IDENTIFIER=pt.exsoria.voice-harness.tests; TEST_TARGET_NAME=VoiceHarness;')]:
    add(prefix + "C", f'isa=XCConfigurationList; buildConfigurations=({prefix}D,{prefix}R); defaultConfigurationIsVisible=0; defaultConfigurationName=Debug;')
    for suffix, name in [("D", "Debug"), ("R", "Release")]:
        add(prefix + suffix, f'isa=XCBuildConfiguration; name={name}; buildSettings={{{settings} SWIFT_OPTIMIZATION_LEVEL="-Onone";}};')
# Xcode project object IDs are hexadecimal, even though the aliases above are
# easier to audit. Replace identifiers as complete tokens only.
import re
ids = {line.split(" =", 1)[0]: f"{index:024X}" for index, line in enumerate(objects, 1)}
pbx = "// !$*UTF8*$!\n{archiveVersion=1; classes={}; objectVersion=56; objects={\n" + "\n".join(objects) + "\n}; rootObject=P;}\n"
pbx = re.sub(r"\b(" + "|".join(sorted(ids, key=len, reverse=True)) + r")\b", lambda match: ids[match[0]], pbx)
(project / "project.pbxproj").write_text(pbx, encoding="utf-8")
schemes = project / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)


def reference(ident, name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids[ident]}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:VoiceHarness.xcodeproj"/>'


app, tests = reference("A", "VoiceHarness.app"), reference("T", "VoiceHarnessUITests.xctest")
(schemes / "VoiceHarness.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{app}</BuildActionEntry>
<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{tests}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{tests}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></LaunchAction>
</Scheme>''')
