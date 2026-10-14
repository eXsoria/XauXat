# iOS notification privacy and consent

XauXat starts with notifications off. A new installation does not ask for iOS
notification permission, register for remote notifications or share an APNs
device token with the XauXat notification server during onboarding.

## Enabling notifications

Selecting Instant or Periodic in `Settings > Notifications` first shows the
privacy boundary for that mode. XauXat only asks iOS for notification
permission after the user accepts that notice. If permission is denied, the
stored notification mode remains Off.

Instant mode has the following boundaries:

- the XauXat notification server receives the APNs device token and separate
  notification queue subscriptions, but not the message queue addresses;
- this lets the notification server infer the number of queues with
  notifications enabled and approximate notification activity;
- the encrypted APNs payload contains no message text or contact identity;
- Apple can observe that the device receives pushes and their timing;
- delivery from the notification server through APNs to the device is outside
  Tor;
- after the encrypted signal arrives, the Notification Service Extension uses
  its own embedded Tor client to retrieve SimpleX data and does not fall back
  to a direct SMP or XFTP connection.

Periodic mode shares the APNs device token with the XauXat notification server,
but does not subscribe the notification server to individual message queues.
Apple still provides the wake-up path outside Tor, and iOS controls when the
background check runs.

Turning notifications off updates the stored intent immediately and removes
the registered token from the XauXat notification server through the existing
registration reconciler.

## Apple capability

The NSE target requests `com.apple.developer.usernotifications.filtering` and
enables the matching silent-filtering and CallKit paths together. The Apple
Developer App ID `pt.exsoria.xauxat.notification-service` must have Notification
(NSE) Filtering enabled and its provisioning profile must be regenerated after
that change. Approval of the capability alone does not update an old profile.

`archive-testflight.sh` rejects an archive or IPA whose NSE signature or embedded
profile does not include the filtering entitlement. It also rejects missing or
inconsistent notification endpoints across the app and both extensions. An
unsigned CI build does not prove that Apple provisioning is correct.

Release builds default to the public XauXat notification endpoint at
`nft.exsoria.pt:8443`, with its CA fingerprint pinned in `Release.xcconfig`.
The endpoint is public configuration; APNs signing keys stay on the server.
Debug builds keep the endpoint empty unless explicitly configured locally:
their sandbox APNs tokens cannot use the production-only APNs key.

APNs delivery, silent filtering, CallKit behaviour and the fail-closed Tor
route remain gated by the two-iPhone matrix in `IOS_NOTIFICATION_TEST_MATRIX.md`.
