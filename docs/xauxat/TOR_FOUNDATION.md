# XauXat native foundation and embedded Tor milestone

Status: iOS implementation in progress, 2026-09-12.

## Product foundation

XauXat is a public native fork of SimpleX Chat. The production client lives in
this repository. The separate Expo project is only a visual and interaction
reference for the later SwiftUI and Compose redesign.

- Upstream: `simplex-chat/simplex-chat`
- Baseline: `stable` 7.0.2, commit `4df04bdb3ff94059734ad2da7d2766de6dba2cc7`
- XauXat integration branch: `xauxat/main`
- iOS: SwiftUI client using the Haskell core through FFI
- Android: Kotlin Multiplatform and Compose client using the Haskell core
- Source and modifications: public under AGPLv3
- Branding: XauXat assets only

## Current milestone

This milestone only integrates and proves embedded Tor. It does not implement
the broader Free or Plus roadmap.

The embedded Tor process belongs to the local mobile client. It is not an
Exsoria relay, does not replace SimpleX servers and does not alter the device's
system proxy or VPN.

### Required behaviour

1. Start Tor before the SimpleX chat controller can connect.
2. Bind control and SOCKS listeners to loopback using app-private dynamic ports.
3. Wait for confirmed bootstrap before applying the SimpleX network config.
4. Set the SimpleX SOCKS proxy to the local listener.
5. Force all SimpleX destinations through SOCKS and prefer onion relay
   addresses where available.
6. Never fall back to a direct connection when Tor is unavailable.
7. Pause messaging while Tor is unhealthy and recover only after a successful
   bootstrap.
8. Keep Tor and proxy controls out of the UI. Show a XauXat connection state
   and retry action instead.

### Shared lifecycle contract

Both platforms expose the same internal state machine:

```text
stopped -> starting -> bootstrapping -> ready
              |              |           |
              +-----------> failed <-----+
```

Only `ready` may create or resume the SimpleX controller. A failure invalidates
the active proxy endpoint immediately. Restart uses a new health-checked
endpoint and never enables a direct fallback.

### iOS

Use a pinned C-Tor framework behind `EmbeddedTorManager`, owned by the app
lifecycle. The prior proof of concept demonstrated app-local SOCKS routing,
dynamic ports and successful Tor and onion requests. C-Tor is the pragmatic
first implementation. A reproducible self-built dependency or Arti must be
evaluated before public release.

Network changes and app resume trigger health checks. The SimpleX controller
must not start before bootstrap completes.

#### Notification service extension

The iOS Notification Service Extension runs in a process that is separate from
the main app. It cannot assume that the app-owned Tor thread or its dynamic
SOCKS port still exists while XauXat is suspended.

The extension therefore has its own pinned C-Tor runtime, private `TorNSE`
state directory and loopback-only dynamic SOCKS listener. Its SimpleX core is
configured with the closed endpoint `127.0.0.1:1` until that Tor instance
reports an established circuit and returns its listener. The extension never
publishes its short-lived port as the main app's port and never falls back to a
direct SMP or XFTP connection. If bootstrap does not complete within 18
seconds, it stops processing and delivers only the opaque best-attempt push so
the remaining iOS execution budget is not exhausted.

APNs transport from the XauXat notification server to the device remains Apple
infrastructure and is not carried by Tor. Tor protection begins only when the
extension wakes and retrieves SimpleX data after receiving that signal.

The extension implementation builds, installs and launches with the full app
on the current arm64 iOS simulator. Background timing, memory limits and direct
socket absence still require the physical-iPhone matrix before this behaviour
can be described as production-verified.

The exact privacy boundary, fail-closed invariants and physical packet-capture
procedure are documented in
[`NSE_TOR_VERIFICATION.md`](NSE_TOR_VERIFICATION.md).

### Android

Use a pinned `tor-android` library behind the same lifecycle contract. Run Tor
inside the XauXat app, expose SOCKS on loopback only and pass that endpoint into
the existing SimpleX `NetCfg` path.

Android background execution and battery restrictions require real-device
testing. XauXat must not require Orbot.

## Privacy boundary for the first beta

"All messaging through Tor" initially means SimpleX SMP and XFTP traffic from
the active app process. The notification extension now has the same fail-closed
routing policy, but needs physical-device proof. These paths must not be
claimed as covered until verified:

- iOS APNs transport to the device, which necessarily remains outside Tor
- iOS notification-extension execution under physical-device limits
- Android background notification service
- WebRTC calls, because Tor does not carry UDP
- URL previews, downloads or integrations outside the SimpleX core
- the share extension on iOS

Calls and unverified network features stay disabled in the first Tor beta. The
fork has separate Apple identifiers and cannot use SimpleX Chat's APNs signing
credentials. Instant iOS notifications are staged behind explicit opt-in with
XauXat App IDs and the approved Notification Filtering entitlement. APNs
credentials, the public notification service and the physical-device matrix
remain release requirements.

## Acceptance evidence

The Tor milestone is complete only after all applicable checks pass on current
arm64 iPhone hardware and supported Android hardware. Simulators are useful for
development but never replace real-device evidence:

- Tor bootstrap reaches 100 percent.
- A Tor check returns `IsTor: true`.
- A real onion endpoint loads through the local SOCKS proxy.
- SimpleX messages and files work through the public preset relays.
- Stopping Tor makes messaging fail closed with no direct retry.
- Restarting Tor restores the SimpleX session without data loss.
- Packet and socket inspection shows no direct SimpleX relay connection.
- Background, foreground, network change and offline recovery are exercised.
- Logs contain no message content, keys, invite secrets or stable user IDs.

## Repository and delivery model

- `upstream/stable`: upstream updates
- `xauxat/main`: protected XauXat integration branch
- `xauxat/tor-foundation`: first implementation branch
- pull requests required for integration
- unsigned arm64 iPhone build with the latest hosted Xcode/iOS SDK on every
  relevant pull request
- Android Foss debug build added after its native-library supply is pinned
- signed iOS archive uploaded to internal TestFlight only from an approved
  release revision
- build metadata records upstream commit, XauXat commit and dependency hashes

GitHub Actions validates the real iPhone architecture. TestFlight delivers
installable iPhone betas.
An Ad Hoc IPA is not the default because it still requires signing, registered
devices and provisioning.

## Compliance gates

Before a beta uses public SimpleX infrastructure:

- publish the complete corresponding XauXat source under AGPLv3
- retain licence and copyright notices
- replace all proprietary SimpleX graphic assets
- do not use SimpleX or SimpleX Chat as XauXat branding
- describe XauXat as an independent client for the SimpleX network
- link the exact source revision from inside the app
- require acceptance of the applicable SimpleX infrastructure conditions
- preserve limits and restrictions required for third-party clients
- do not charge for access to preset operators' infrastructure
- do not add analytics or tracking
- obtain legal review before public App Store distribution

Primary references:

- <https://github.com/simplex-chat/simplex-chat>
- <https://github.com/simplex-chat/simplex-chat/blob/stable/PRIVACY.md>
- <https://github.com/simplex-chat/simplex-chat/blob/stable/docs/TRADEMARK.md>
- <https://github.com/simplex-chat/simplex-chat/blob/stable/assets/ASSETS_LICENSE.md>
- <https://simplex.chat/faq/>
- <https://github.com/guardianproject/tor-android>
- <https://github.com/iCepa/Tor.framework>
- <https://developer.apple.com/testflight/>
