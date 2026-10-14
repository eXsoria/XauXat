# XauXat TestFlight delivery

TestFlight is the intended iPhone beta channel. The pull-request workflow
proves the native core, unsigned device build and launched simulator build. A
TestFlight build additionally needs Apple-owned identifiers, production
provisioning and App Store Connect authentication.

## Canonical Apple identifiers

Use the identifiers in `IOS_APP_IDENTIFIERS.md`:

- app: `pt.exsoria.xauxat`
- notification service extension: `pt.exsoria.xauxat.notification-service`
- share extension: `pt.exsoria.xauxat.share`
- app group: `group.pt.exsoria.xauxat`

Do not create aliases using the old `dev.exsoria` or SimpleX identifiers.

## One-time Apple Developer setup

In Certificates, Identifiers & Profiles:

1. Open the explicit App ID `pt.exsoria.xauxat`.
2. Enable Associated Domains, App Groups and Push Notifications. Assign
   `group.pt.exsoria.xauxat`, then save and confirm.
3. Open `pt.exsoria.xauxat.notification-service` and
   `pt.exsoria.xauxat.share`. Enable App Groups and assign the same group to
   each extension.
   On the notification-service App ID, also enable the approved Notification
   (NSE) Filtering capability. The NSE requests
   `com.apple.developer.usernotifications.filtering`; its profile must grant it.
4. Regenerate profiles affected by the capability change, or let Xcode manage
   them automatically on the next archive with `-allowProvisioningUpdates`.
5. In Xcode Settings > Accounts, make sure the intended team is signed in.

The initial TestFlight build does not request Multicast Networking. Local
multicast desktop discovery is disabled in the iOS UI until the managed
capability is approved and deliberately enabled in a later release.

## One-time App Store Connect setup

Create the app record before uploading the first build:

| Field | Value |
| --- | --- |
| Platforms | iOS |
| Name | XauXat |
| Primary Language | English (U.S.) |
| Bundle ID | `pt.exsoria.xauxat` |
| SKU | `XAUXAT-IOS-001` |
| User Access | Full Access |

The Account Holder must accept any pending agreements before the app record can
be created. The app name may need a temporary suffix in App Store Connect if
Apple reports that `XauXat` is unavailable; this does not change the on-device
name or bundle identifier.

## Produce and validate the archive

Download the `XauXat-iOS-Native-Core-*` artifact produced for the exact release
revision and place `pkg-ios-aarch64-swift-json.zip` in a local directory. Then:

```bash
./scripts/ios/archive-testflight.sh \
  --team-id '<APPLE_TEAM_ID>' \
  --native-core-archive-dir .xauxat-cache/ios-libs
```

The script:

- prepares the fork-built native core for iPhone;
- installs the pinned Tor CocoaPod;
- runs the notification/Tor policy checks;
- creates a Release archive with automatic signing;
- verifies production APNs, App Groups, keychain groups
  and every XauXat bundle identifier from the signed entitlements;
- verifies the NSE filtering entitlement in both the signature and embedded
  provisioning profile, and a configured NTF endpoint shared by all bundles;
- exports and re-verifies the App Store Connect IPA.

Outputs are written to `.xauxat-release/`, which is gitignored. A previous
output is never overwritten.

Release builds include `nft.exsoria.pt:8443` and its public pinned CA fingerprint
by default. Remove any stale empty `XAUXAT_NTF_SERVER_B64` override from
`apps/ios/Local.xcconfig` before archiving. Never copy the server's APNs `.p8`
key into the app or CI: that key cannot sign an iOS application.

The iOS GitHub Actions workflow compiles the Release device app without code
signing and launches a Debug simulator app. These checks can run while the
developer is on Windows. The resulting unsigned `.app` cannot be installed
through TestFlight. Signed distribution still needs an Apple Distribution
identity (certificate plus private key) and updated profiles, either on a Mac
or securely installed in a separate macOS CI distribution workflow.

To archive, validate and upload directly after the App Store Connect record
exists:

```bash
./scripts/ios/archive-testflight.sh \
  --team-id '<APPLE_TEAM_ID>' \
  --native-core-archive-dir .xauxat-cache/ios-libs \
  --upload
```

The upload flag is an explicit external action. Without it, the script only
creates a local IPA that can be uploaded with Xcode Organizer or Transporter.

## TestFlight setup after upload

Apple must process the build before it appears in App Store Connect. For the
first beta:

1. Open XauXat > TestFlight and wait for version `0.0.1` build `3` to finish
   processing. Build `3` includes Plus access for all beta testers. Build `1`
   was rejected by automated processing because its pinned SwiftyGif revision
   predated the SDK privacy-manifest requirement; build `2` fixed that manifest
   but still expected the StoreKit subscription product.
2. Complete the export-compliance status shown for the build. XauXat contains
   its own encryption and Tor, so confirm the answers against the actual
   cryptography and intended countries; do not guess or claim an exemption
   solely to clear the warning.
3. Fill Beta App Description, Feedback Email, Contact Information and What to
   Test.
4. Create an Internal Testing group first. Internal testers must be App Store
   Connect users with access to XauXat.
5. For friends who are not App Store Connect users, create an External Testing
   group, add the build, provide review notes and submit it for TestFlight App
   Review. After approval, invite by email or enable a public link.

Suggested beta description:

> XauXat is a privacy-first messaging app based on the SimpleX protocol. This
> beta focuses on account-free messaging, embedded Tor routing, local encrypted
> storage and privacy-safe notifications.

Suggested What to Test:

> Create a profile, connect two devices using an invitation link or QR code,
> exchange text, photos, audio and files, place an audio call, and verify that
> notifications do not expose message content. Please report connection delays,
> failed deliveries, crashes and screens that do not match the XauXat design.

Suggested beta review note:

> XauXat does not require an email address, phone number or account. Testing the
> complete messaging flow requires two devices. The app starts and manages its
> embedded Tor connection automatically, so the first network connection can
> take longer than later launches.

TestFlight builds remain available for 90 days. The first external build
requires beta review; later builds may be approved without a full review.

## Manual GitHub distribution from Windows

`XauXat TestFlight` is a manually dispatched workflow, restricted to
`xauxat/main`. It never signs pull-request code or uploads automatically after
a push. Before dispatching it, install the signing material securely:

| Repository setting | Purpose |
| --- | --- |
| Variable `XAUXAT_DEVELOPMENT_TEAM` | Apple team ID |
| Secret `IOS_DISTRIBUTION_P12_BASE64` | Base64 Apple Distribution certificate and private key |
| Secret `IOS_DISTRIBUTION_P12_PASSWORD` | Password protecting that PKCS#12 file |
| Secret `IOS_APPSTORE_PROFILE_BASE64` | Base64 App Store profile for the main app |
| Secret `IOS_NSE_APPSTORE_PROFILE_BASE64` | Base64 App Store profile for the NSE, including filtering |
| Secret `IOS_SHARE_APPSTORE_PROFILE_BASE64` | Base64 App Store profile for the share extension |
| Secret `APP_STORE_CONNECT_KEY_P8` | App Store Connect API key PEM, only needed for upload |
| Secret `APP_STORE_CONNECT_KEY_ID` | Its key ID |
| Secret `APP_STORE_CONNECT_ISSUER_ID` | Its issuer ID |

The App Store Connect API key is separate from the notification server's APNs
key. Certificate private keys, profile files, passwords and API keys must never
be committed. Profiles must use the installed distribution certificate and the
correct bundle IDs and App Group. A new dedicated CI distribution certificate
can be requested from Windows without exporting the Mac's existing private key.

First merge the reviewed changes and let `XauXat iOS` pass for that exact main
commit. Supply that successful push workflow's run ID to `native_core_run_id`,
choose an unused build number (the next candidate after build 12 is 13), and
leave `upload` false for the first signing run. The workflow downloads only
the matching successful main native-core artifact, installs signing material
in an ephemeral keychain, and checks the signed archive and exported IPA.
It removes the signing material on exit and stores the IPA for seven days.
That first run is the signing validation when a local Mac is unavailable;
unsigned PR checks cannot substitute for it.

After inspecting the first signed result, dispatch a new run with `upload`
true to upload to App Store Connect. Use a fresh build number if a prior upload
already succeeded. The API key needs a role that can upload builds, such as
Developer. TestFlight tester rollout and physical-device acceptance remain
separate from generating or uploading an IPA.
