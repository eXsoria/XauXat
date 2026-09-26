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

The Notification Service Extension target carries
`com.apple.developer.usernotifications.filtering`. This managed entitlement is
scoped to `pt.exsoria.xauxat.notification-service`; it allows the extension to
return empty notification content for suppressed events. The temporary generic
fallback used while Apple approval was pending is no longer active.

Approval and source configuration are not production proof. Release signing
must embed a provisioning profile that grants this entitlement. APNs delivery,
silent filtering, CallKit behaviour and the fail-closed Tor route remain gated
by the two-iPhone matrix in `IOS_NOTIFICATION_TEST_MATRIX.md`.
