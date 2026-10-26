"""Build a simulator harness around the production expression library and tray."""
from pathlib import Path
import re
import shutil
import sys

root, out = map(Path, sys.argv[1:])
out.mkdir(parents=True, exist_ok=True)
for name in ("Harness.swift", "UITests.swift"):
    shutil.copyfile(root / "scripts/ios/expression-tests" / name, out / name)
source = root / "apps/ios/Shared/Views/Chat/ComposeMessage"
for original, name in [("XauXatExpressionLibrary.swift", "Library.swift"), ("XauXatExpressionsView.swift", "Tray.swift")]:
    shutil.copyfile(source / original, out / name)

project = out / "ExpressionsHarness.xcodeproj"
project.mkdir(exist_ok=True)
objects = []


def add(ident, body):
    assert all(not line.startswith(ident + " =") for line in objects), ident
    objects.append(f"{ident} = {{{body}}};")


add("P", 'isa=PBXProject; buildConfigurationList=PC; compatibilityVersion="Xcode 14.0"; developmentRegion=en; knownRegions=(en,Base); mainGroup=G; productRefGroup=PG; projectDirPath=""; projectRoot=""; targets=(A,T); attributes={LastUpgradeCheck=1600; TargetAttributes={T={TestTargetID=A;};};};')
add("G", 'isa=PBXGroup; children=(F1,F2,F3,F4,PG); sourceTree="<group>";')
add("PG", 'isa=PBXGroup; name=Products; children=(AP,TP); sourceTree="<group>";')
for i, name in enumerate(["Harness.swift", "Library.swift", "Tray.swift", "UITests.swift"], 1):
    add(f"F{i}", f'isa=PBXFileReference; lastKnownFileType=sourcecode.swift; path={name}; sourceTree="<group>";')
    add(f"B{i}", f"isa=PBXBuildFile; fileRef=F{i};")
add("AP", 'isa=PBXFileReference; explicitFileType=wrapper.application; path=ExpressionsHarness.app; sourceTree=BUILT_PRODUCTS_DIR;')
add("TP", 'isa=PBXFileReference; explicitFileType=wrapper.cfbundle; path=ExpressionsHarnessUITests.xctest; sourceTree=BUILT_PRODUCTS_DIR;')
add("AS", "isa=PBXSourcesBuildPhase; buildActionMask=2147483647; files=(B1,B2,B3); runOnlyForDeploymentPostprocessing=0;")
add("TS", "isa=PBXSourcesBuildPhase; buildActionMask=2147483647; files=(B4); runOnlyForDeploymentPostprocessing=0;")
add("A", 'isa=PBXNativeTarget; buildConfigurationList=AC; buildPhases=(AS); buildRules=(); dependencies=(); name=ExpressionsHarness; productName=ExpressionsHarness; productReference=AP; productType="com.apple.product-type.application";')
add("T", 'isa=PBXNativeTarget; buildConfigurationList=TC; buildPhases=(TS); buildRules=(); dependencies=(DEP); name=ExpressionsHarnessUITests; productName=ExpressionsHarnessUITests; productReference=TP; productType="com.apple.product-type.bundle.ui-testing";')
add("DEP", "isa=PBXTargetDependency; target=A; targetProxy=PX;")
add("PX", "isa=PBXContainerItemProxy; containerPortal=P; proxyType=1; remoteGlobalIDString=A; remoteInfo=ExpressionsHarness;")
common = 'SDKROOT=iphoneos; IPHONEOS_DEPLOYMENT_TARGET=15.0; SWIFT_VERSION=5.0; CODE_SIGNING_ALLOWED=NO; TARGETED_DEVICE_FAMILY=1; GENERATE_INFOPLIST_FILE=YES; CURRENT_PROJECT_VERSION=1; MARKETING_VERSION=1.0; PRODUCT_NAME="$(TARGET_NAME)";'
for prefix, settings in [("P", common), ("A", 'PRODUCT_BUNDLE_IDENTIFIER=pt.exsoria.expressions-harness; INFOPLIST_KEY_UILaunchScreen_Generation=YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation=YES;'), ("T", 'PRODUCT_BUNDLE_IDENTIFIER=pt.exsoria.expressions-harness.tests; TEST_TARGET_NAME=ExpressionsHarness;')]:
    add(prefix + "C", f"isa=XCConfigurationList; buildConfigurations=({prefix}D,{prefix}R); defaultConfigurationIsVisible=0; defaultConfigurationName=Debug;")
    for suffix, name in [("D", "Debug"), ("R", "Release")]:
        add(prefix + suffix, f'isa=XCBuildConfiguration; name={name}; buildSettings={{{settings} SWIFT_OPTIMIZATION_LEVEL="-Onone";}};')
ids = {line.split(" =", 1)[0]: f"{index:024X}" for index, line in enumerate(objects, 1)}
pbx = "// !$*UTF8*$!\n{archiveVersion=1; classes={}; objectVersion=56; objects={\n" + "\n".join(objects) + "\n}; rootObject=P;}\n"
pbx = re.sub(r"\b(" + "|".join(sorted(ids, key=len, reverse=True)) + r")\b", lambda m: ids[m[0]], pbx)
(project / "project.pbxproj").write_text(pbx)
schemes = project / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)


def reference(ident, name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids[ident]}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:ExpressionsHarness.xcodeproj"/>'


app, tests = reference("A", "ExpressionsHarness.app"), reference("T", "ExpressionsHarnessUITests.xctest")
(schemes / "ExpressionsHarness.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{app}</BuildActionEntry>
<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{tests}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{tests}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></LaunchAction>
</Scheme>''')
