# XauXat Desktop

## Scope and status

The requested product is XauXat Desktop for Windows, macOS and Linux, based on the native Kotlin/Compose Desktop client already in this fork. The first milestone, chosen by the owner, is an internal beta for iPhone linking and operating the VPS support profile. Full iOS-specific privacy/feature parity is a later release gate. The window title and onboarding identify this beta and its test-profile scope.

Initial build targets:

| OS | Architecture | Native package target |
| --- | --- | --- |
| Windows | x86_64 | MSI / EXE |
| macOS | Apple Silicon | DMG |
| macOS | Intel | DMG |
| Linux | x86_64 | DEB initially |

The workflow compiles actual Desktop Kotlin/Compose sources and runs JVM tests on all four runners. A separate job per target builds this fork's Haskell core and JNI, packages an internal MSI/DMG/DEB, and verifies native database migrations/commands and actual Compose window startup from the bundled app image. JVM checks alone do not prove native loading. A package is uploaded only after its packaged startup checks pass. Physical iPhone/CLI pairing remains a separate acceptance test. No GitHub Release or tester notification is created. The repository is public, so Actions artifacts must contain no credentials, profiles or user data.

## Product identity

- App/package display name: XauXat (Linux package: `xauxat`).
- macOS bundle identifier: `pt.exsoria.xauxat.desktop`.
- Windows has a different MSI upgrade UUID from SimpleX.
- Windows data/config: `%APPDATA%/XauXat`.
- Unix data/config: `${XDG_DATA_HOME:-~/.local/share}/xauxat` and `${XDG_CONFIG_HOME:-~/.config}/xauxat`.
- Existing SimpleX databases/preferences are neither imported nor overwritten automatically.
- Desktop temporary files live under the XauXat data directory, so startup cleanup cannot delete SimpleX's shared temporary directory.
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

`scripts/desktop/build-internal-beta.py` is restricted to ephemeral Actions runners. It builds the core from the checked-out source with GHC 9.6.3 and pinned Cabal dependencies, builds SHA-256-verified OpenSSL 3.5.9 LTS, verifies the VLC v3.0.23-2 archive, relocates runtime libraries and builds JNI. It does not invoke the legacy scripts' recursive cleanup or shared `/tmp/tmp` downloads. The GHC Windows DLL-export workaround is restored in `finally`; the builder refuses an existing `cabal.project.local`. Native libraries and source commit/dependency hashes are recorded in `BUILD-PROVENANCE.json`.

Packages are unsigned (macOS native libraries are ad-hoc signed) and not notarized. Existing iOS signing credentials are not used for Desktop. Linux is initially built and tested on Ubuntu 24.04 x86_64; compatibility with older distributions is not claimed. `PACKAGED-SMOKE.json` distinguishes automated native/GUI checks from pending physical pairing. Smoke tests use temporary HOME/APPDATA/XDG locations and JVM user.home, not the operator's live profile. These tests exercise startup, not complete messaging or multimedia acceptance.

On macOS, the builder selects an installed stable Xcode 26 toolchain when available and retargets GHC's baked-in Command Line Tools SDK references to that selected SDK. This avoids mixing a newer CLT SDK with an older linker. Changes to the ephemeral GHC configuration are restored after the build. Native compilation targets macOS 13; automated packaged startup is only evidence for the actual Intel/Apple Silicon runner OS, not acceptance on every older macOS version. The selected SDK and deployment target are recorded in provenance.

## Release gates

A public XauXat desktop release still requires all of the following:

1. Passing source/JVM tests on Windows, macOS Apple Silicon, macOS Intel and Linux.
2. Fork-native core/JNI builds per target, verified media/runtime dependencies, and successful packaged launch. Include provenance/digests with CI artifacts; do not claim bit-for-bit reproducibility without measuring it.
3. A physical test linking the XauXat iPhone and an operator test controlling/replying through the existing VPS support profile.
4. Ordinary message/file/group compatibility tests with the current iOS build, plus reconnect, suspend/resume, network-change, restart and notification tests on each OS.
5. Port or explicitly exclude XauXat protected/custom content, hidden-chat/profile policy, code locks, one-time-view rules, duress/decoy behavior and Plus semantics. Current Kotlin models do not yet implement the custom XauXat image format. Unknown-message fallback is not a substitute for a protection policy.
6. A verified desktop network policy. The existing desktop client does not inherit the iOS embedded-Tor manager or its fail-closed policy. Do not advertise equivalent Tor guarantees until implemented and tested. Linked-mode notifications and previews also require a privacy audit.
7. XauXat-specific onboarding/help/release notes and source/license attribution. Remaining upstream product descriptions and links must be reviewed rather than mechanically deleting dependency attribution.
8. XauXat signing/distribution setup and update/recovery verification. iOS distribution credentials are not automatically a desktop signing configuration.

This work is separate from the existing iOS recovery/support PRs. It does not need to delay validating the already deployed support profile through its SSH console. A desktop foundation build is not evidence that all iOS-only security features have been ported.
