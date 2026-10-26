"""Build simulator tests with the actual home destination, row and action sheets."""
from pathlib import Path
import shutil
import sys

root, out = map(Path, sys.argv[1:])
fixtures = root / "scripts/ios/home-chat-tests"
out.mkdir(parents=True, exist_ok=True)
for name in ("Harness.swift", "UITests.swift"):
    shutil.copyfile(fixtures / name, out / name)
source = (root / "apps/ios/Shared/Views/XauXatHomeView.swift").read_text(encoding="utf-8")
palette = source[source.index("private struct XauXatPalette {"):source.index("private enum XauXatOnboardingField:")]
rows = source[source.index("private struct XauXatChatDestination:"):source.index("private struct XauXatEmptyState:")]
# File-level access only; leave the implementation and nested private members intact.
rows = rows.replace("private struct ", "struct ")
palette = palette.replace("private struct ", "struct ")
(out / "Rows.swift").write_text("import SwiftUI\n" + palette + rows, encoding="utf-8")

project = out / "HomeChatHarness.xcodeproj"
project.mkdir(exist_ok=True)
objects = []


def add(ident, body):
    assert all(not line.startswith(ident + " =") for line in objects), ident
    objects.append(f"{ident} = {{{body}}};")


add("P", "isa=PBXProject; buildConfigurationList=PC; compatibilityVersion=\"Xcode 14.0\"; developmentRegion=en; knownRegions=(en,Base); mainGroup=G; productRefGroup=PG; projectDirPath=\"\"; projectRoot=\"\"; targets=(A,T); attributes={LastUpgradeCheck=1600; TargetAttributes={T={TestTargetID=A;};};};")
add("G", "isa=PBXGroup; children=(F1,F2,F3,PG); sourceTree=\"<group>\";")
add("PG", "isa=PBXGroup; name=Products; children=(AP,TP); sourceTree=\"<group>\";")
for ident, path, kind in [("F1", "Harness.swift", "sourcecode.swift"), ("F2", "Rows.swift", "sourcecode.swift"), ("F3", "UITests.swift", "sourcecode.swift")]:
    add(ident, f'isa=PBXFileReference; lastKnownFileType={kind}; path={path}; sourceTree="<group>";')
add("AP", 'isa=PBXFileReference; explicitFileType=wrapper.application; path=HomeChatHarness.app; sourceTree=BUILT_PRODUCTS_DIR;')
add("TP", 'isa=PBXFileReference; explicitFileType=wrapper.cfbundle; path=HomeChatHarnessUITests.xctest; sourceTree=BUILT_PRODUCTS_DIR;')
for ident, ref in [("B1", "F1"), ("B2", "F2"), ("B3", "F3")]:
    add(ident, f"isa=PBXBuildFile; fileRef={ref};")
add("AS", "isa=PBXSourcesBuildPhase; buildActionMask=2147483647; files=(B1,B2); runOnlyForDeploymentPostprocessing=0;")
add("TS", "isa=PBXSourcesBuildPhase; buildActionMask=2147483647; files=(B3); runOnlyForDeploymentPostprocessing=0;")
add("A", 'isa=PBXNativeTarget; buildConfigurationList=AC; buildPhases=(AS); buildRules=(); dependencies=(); name=HomeChatHarness; productName=HomeChatHarness; productReference=AP; productType="com.apple.product-type.application";')
add("T", 'isa=PBXNativeTarget; buildConfigurationList=TC; buildPhases=(TS); buildRules=(); dependencies=(DEP); name=HomeChatHarnessUITests; productName=HomeChatHarnessUITests; productReference=TP; productType="com.apple.product-type.bundle.ui-testing";')
add("DEP", "isa=PBXTargetDependency; target=A; targetProxy=PX;")
add("PX", "isa=PBXContainerItemProxy; containerPortal=P; proxyType=1; remoteGlobalIDString=A; remoteInfo=HomeChatHarness;")
common = 'SDKROOT=iphoneos; IPHONEOS_DEPLOYMENT_TARGET=15.0; SWIFT_VERSION=5.0; CODE_SIGNING_ALLOWED=NO; TARGETED_DEVICE_FAMILY=1; GENERATE_INFOPLIST_FILE=YES; CURRENT_PROJECT_VERSION=1; MARKETING_VERSION=1.0; PRODUCT_NAME="$(TARGET_NAME)";'
for prefix, settings in [("P", common), ("A", 'PRODUCT_BUNDLE_IDENTIFIER=pt.exsoria.home-chat-harness; INFOPLIST_KEY_UILaunchScreen_Generation=YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation=YES;'), ("T", 'PRODUCT_BUNDLE_IDENTIFIER=pt.exsoria.home-chat-harness.tests; TEST_TARGET_NAME=HomeChatHarness;')]:
    add(prefix + "C", f'isa=XCConfigurationList; buildConfigurations=({prefix}D,{prefix}R); defaultConfigurationIsVisible=0; defaultConfigurationName=Debug;')
    for suffix, name in [("D", "Debug"), ("R", "Release")]:
        add(prefix + suffix, f'isa=XCBuildConfiguration; name={name}; buildSettings={{{settings} SWIFT_OPTIMIZATION_LEVEL="-Onone";}};')
# Xcode project object IDs are hexadecimal, even though the aliases above are
# easier to audit. Replace identifiers as complete tokens only.
import re
ids = {line.split(" =", 1)[0]: f"{index:024X}" for index, line in enumerate(objects, 1)}
pbx = "// !$*UTF8*$!\n{archiveVersion=1; classes={}; objectVersion=56; objects={\n" + "\n".join(objects) + "\n}; rootObject=P;}\n"
pbx = re.sub(r"\b(" + "|".join(sorted(ids, key=len, reverse=True)) + r")\b", lambda match: ids[match[0]], pbx)
(project / "project.pbxproj").write_text(pbx)
schemes = project / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)


def reference(ident, name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids[ident]}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:HomeChatHarness.xcodeproj"/>'


app, tests = reference("A", "HomeChatHarness.app"), reference("T", "HomeChatHarnessUITests.xctest")
(schemes / "HomeChatHarness.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{app}</BuildActionEntry>
<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{tests}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{tests}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></LaunchAction>
</Scheme>''')
