# XauXat iOS identifiers and signing

These are the canonical identifiers for every XauXat iOS build.

| Component | Identifier |
| --- | --- |
| Main app | `pt.exsoria.xauxat` |
| Notification Service Extension | `pt.exsoria.xauxat.notification-service` |
| Share Extension | `pt.exsoria.xauxat.share` |
| Core framework | `pt.exsoria.xauxat.core` |
| Test target | `pt.exsoria.xauxat.tests` |
| App Group | `group.pt.exsoria.xauxat` |
| Keychain access group suffix | `pt.exsoria.xauxat` |
| Background task | `pt.exsoria.xauxat.receive` |

The `simplex://` URL scheme and the SimpleX associated domains remain intentionally enabled so XauXat can open links from the SimpleX ecosystem. They are protocol interoperability settings, not SimpleX signing identities.

## Apple Developer setup

Create three explicit App IDs in the Apple Developer portal for the main app, notification extension and share extension. Create `group.pt.exsoria.xauxat`, then enable it for all three App IDs. Enable Keychain Sharing for all three targets with `$(AppIdentifierPrefix)pt.exsoria.xauxat`.

Enable Push Notifications on the main App ID. The project already declares `remote-notification`, `fetch`, `audio` and `voip` background modes. The Debug app entitlement uses the APNs `development` environment and the Release app entitlement uses `production`.

The initial TestFlight build does not request the Apple-managed Multicast
Networking entitlement. Local multicast discovery is disabled in the iOS UI,
while QR/address-based desktop pairing and the underlying SimpleX implementation
remain in the source. If multicast discovery is enabled in a later release,
first obtain Apple's approval, enable the capability on `pt.exsoria.xauxat`, and
regenerate the affected profiles.

Create matching development and distribution provisioning profiles after enabling those capabilities. Do not commit APNs private keys, certificates, provisioning profiles or the Apple team ID. Supply the team locally or in CI as a protected setting:

```bash
xcodebuild \
  -workspace apps/ios/SimpleX.xcworkspace \
  -scheme 'SimpleX (iOS)' \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  XAUXAT_DEVELOPMENT_TEAM='<APPLE_TEAM_ID>' \
  build
```

For Xcode UI builds, define `XAUXAT_DEVELOPMENT_TEAM` in a user-local `.xcconfig` or as a user-defined build setting. Never add the real value to the repository.

For an App Store Connect archive and validated IPA, use
`scripts/ios/archive-testflight.sh`; the full flow is documented in
`TESTFLIGHT.md`.

## Verification

After building, validate the produced app and its embedded extensions:

```bash
./scripts/ios/verify-xauxat-identifiers.sh /path/to/SimpleX.app development
codesign -d --entitlements :- /path/to/SimpleX.app
codesign -d --entitlements :- '/path/to/SimpleX.app/PlugIns/SimpleX NSE.appex'
codesign -d --entitlements :- '/path/to/SimpleX.app/PlugIns/SimpleX SE.appex'
```

On a physical device, confirm that registration reaches `didRegisterForRemoteNotificationsWithDeviceToken`, then test a real development APNs notification. Repeat with an archived Release/TestFlight build against production APNs. Logs may report registration success and APNs environment, but must never print a device token or notification payload.

The new App Group deliberately isolates XauXat from data belonging to an installed SimpleX app. The app, NSE and share extension must all resolve the same App Group and Keychain access group before shipping.
