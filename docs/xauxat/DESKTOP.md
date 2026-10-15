# XauXat Desktop

## Scope and status

The requested product is XauXat Desktop for Windows, macOS and Linux, based on the native Kotlin/Compose Desktop client already in this fork. This branch establishes a separate product identity and build-validation path; it is not yet a tested or signed desktop release, and does not claim parity with the iOS-only XauXat protections.

Initial build targets:

| OS | Architecture | Native package target |
| --- | --- | --- |
| Windows | x86_64 | MSI / EXE |
| macOS | Apple Silicon | DMG |
| macOS | Intel | DMG |
| Linux | x86_64 | DEB initially |

The current workflow compiles the actual Desktop Kotlin/Compose sources and runs JVM tests on all four runners. It deliberately excludes native CMake packaging; a green JVM build does not prove native-library loading, a working installer, or iPhone/CLI interoperability. No public release is created by this workflow.

## Product identity

- App/package display name: XauXat (Linux package: `xauxat`).
- macOS bundle identifier: `pt.exsoria.xauxat.desktop`.
- Windows has a different MSI upgrade UUID from SimpleX.
- Windows data/config: `%APPDATA%/XauXat`.
- Unix data/config: `${XDG_DATA_HOME:-~/.local/share}/xauxat` and `${XDG_CONFIG_HOME:-~/.config}/xauxat`.
- Existing SimpleX databases/preferences are neither imported nor overwritten automatically.
- Original protocol/JNI package names are retained for compatibility; upstream license/copyright attribution is retained. Product identity is separate from protocol identifiers.
- Icons reuse existing XauXat app pixels. The Windows ICO and macOS ICNS are containers around existing PNG images, not newly generated artwork.
- Support uses the real XauXat native business address through the existing verified-link/connection planner; it does not email the upstream team.
- The desktop update checker is disabled at both scheduled and manual entry points, with controls hidden. Its future feed points at eXsoria/XauXat and platform asset names are XauXat-specific. Signed package replacement and authentication still need review before re-enabling updates.

## User and operator modes

The upstream native client already implements both a local desktop profile and a remotely controlled mobile/CLI profile. Neither is implemented by copying a live iPhone database onto the desktop.

For a linked iPhone, the phone remains the running profile and must be reachable. Use the normal native linking UI on the same local network; verify the pairing code on both devices. This is remote access to a live profile, not independent cloud synchronization or a promise of an offline desktop copy.

For XauXat support, the existing VPS CLI remains the owner of its dedicated business profile. Desktop can control it via the documented native remote-control protocol and a loopback-only SSH reverse tunnel. Pair only after comparing verification codes. Do not expose the controller port or clone the live CLI databases into another networked client.

Sources: [SimpleX desktop downloads/linking](https://simplex.chat/downloads/), [SimpleX team's cloud support setup](https://simplex.chat/docs/business.html).

## Build and validation

The repository's build baseline is Kotlin 2.1.20, Compose 1.8.2, Gradle 8.12 and JDK 17. Desktop native libraries are built from the Haskell fork through the existing platform scripts; do not silently substitute an upstream binary and call it a fork-native build.

JVM source/tests, without native packaging:

```sh
cd apps/multiplatform
./gradlew --no-daemon :common:desktopTest :desktop:compileKotlinJvm -x :desktop:cmakeBuildAndCopy
```

A fresh checkout needs recursive submodules, including nanohttpd. The JVM task exclusion is for compile/test validation only: a runnable app still requires its matching native libraries and resources.

Native build scripts already exist under `scripts/desktop`, but their compiler/dependency versions, download verification and cleanup operations must be reviewed before the new distribution pipeline runs them. Use an isolated build workspace on each target OS. Keep Windows native toolchain and filesystem operations in one shell, and verify resolved cleanup targets remain inside that workspace. Avoid global GHC settings changes on the user's workstation.

## Release gates

A public XauXat desktop release still requires all of the following:

1. Passing source/JVM tests on Windows, macOS Apple Silicon, macOS Intel and Linux.
2. Reproducible fork-native core/JNI builds per target, verified media/runtime dependencies, and successful packaged launch. Include provenance/digests with private CI artifacts.
3. A physical test linking the XauXat iPhone and an operator test controlling/replying through the existing VPS support profile.
4. Ordinary message/file/group compatibility tests with the current iOS build, plus reconnect, suspend/resume, network-change, restart and notification tests on each OS.
5. Port or explicitly exclude XauXat protected/custom content, hidden-chat/profile policy, code locks, one-time-view rules, duress/decoy behavior and Plus semantics. Current Kotlin models do not yet implement the custom XauXat image format. Unknown-message fallback is not a substitute for a protection policy.
6. A verified desktop network policy. The existing desktop client does not inherit the iOS embedded-Tor manager or its fail-closed policy. Do not advertise equivalent Tor guarantees until implemented and tested. Linked-mode notifications and previews also require a privacy audit.
7. XauXat-specific onboarding/help/release notes and source/license attribution. Remaining upstream product descriptions and links must be reviewed rather than mechanically deleting dependency attribution.
8. XauXat signing/distribution setup and update/recovery verification. iOS distribution credentials are not automatically a desktop signing configuration.

This work is separate from the existing iOS recovery/support PRs. It does not need to delay validating the already deployed support profile through its SSH console. A desktop foundation build is not evidence that all iOS-only security features have been ported.
