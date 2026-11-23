# Embedded Tor dependency

The iOS app and notification service extension both use Tor.framework **409.17.1**:

| Component | Version |
| --- | --- |
| Tor | 0.4.9.17 |
| Objective-C wrapper | 409.17.1 (`9c5df82840cd83a62b592293c2e53249ffa1e083`) |
| OpenSSL | 3.6.5 |
| libevent | 2.1.13 |

We use the NoLZMA binary, so liblzma is not included. Arti is not used.

## CocoaPods compatibility

Upstream stopped publishing CocoaPods specs after 409.15.1. Its latest Swift
package requires Swift tools 6.3 / Xcode 27, while XauXat's build uses Xcode 26.3.
`apps/ios/podspecs/Tor.podspec.json` packages the **latest upstream sources
and binary** with the existing CocoaPods integration. It is not an older wrapper
around a newer engine, and it does not modify upstream's Swift package manifest.

The spec pins the wrapper's full commit and verifies the release archive's SHA-256
before extraction. Both app and NSE use the same spec, lockfile and patches.
The archive digest matches upstream's 409.17.1 `Package.swift` and release metadata:

`39579058d205389ce6aaeda6b152b730bed18032ec987487218f9466e9cd6c49`

The 409.17.1 SOCKS5 API changes affect helper methods which XauXat does not call.
Our managers query `net/listeners/socks` directly and validate a loopback endpoint.
The wrapper's newer observer-token removal fix is retained and regression tested.

## Required local fixes

The latest wrapper still needs our socket lifecycle fixes: release descriptors on
connect failure, avoid retaining a stale controller through its I/O channel,
invalidate the connection at EOF, and register command observers before writing.
`xauxatCloseControlSocket` closes only the local control socket without shutting
down the embedded runtime. The patch now preserves upstream's `TORObserverEntry`
objects and stable observer tokens.

`TORThread.m` also still writes `argv[argc] = NULL` beyond an `argc`-sized array.
The bounded thread patch allocates `argc + 1` elements. Both patch scripts accept
only the exact reviewed original or patched source hashes and are idempotent.

## Validation and future updates

On macOS with CocoaPods 1.17.0:

```sh
python3 scripts/ios/verify-tor-dependency.py
pod install --project-directory=apps/ios --deployment
python3 scripts/ios/verify-tor-dependency.py --installed
bash scripts/ios/test-tor-dependency.sh
bash scripts/ios/test-tor-controller.sh
bash scripts/ios/test-tor-recovery.sh
bash scripts/ios/verify-nse-tor-policy.sh
```

The engine test runs the actual downloaded engine via `TORThread`: the pristine
wrapper must reproduce its stack overflow under AddressSanitizer; the patched
wrapper must report Tor 0.4.9.17 without that error. Installed-payload checks cover
ARM64 iOS device and simulator slices and their Tor/OpenSSL versions. The normal
iOS workflow builds the real app and NSE, and the archive script verifies the
installed dependency before creating a TestFlight archive.

For another update, review upstream's sources and release notes, update the exact
commit/archive pins and version checks, rebase the bounded patches, regenerate
`Podfile.lock` with CocoaPods 1.17.0, and run these checks plus the full iOS build.
Keep the existing fail-closed routing and separate NSE runtime policies.
