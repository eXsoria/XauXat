# iOS notification privacy policy

XauXat treats every system notification surface as observable by somebody
other than the account owner. Contact names, profile names, group names and
message content therefore stay out of notification banners and CallKit even
when the corresponding chat is not locked.

## Visible system content

- A normal message or contact event uses generic XauXat wording.
- A normal audio call identifies itself only as a XauXat call. CallKit still
  receives the internal contact and call identifiers needed to open the call,
  but those values are not used as visible labels.
- A locked conversation may produce only generic activity text. Opening it
  still requires the conversation lock.
- A hidden chat or protected profile produces no banner, sound, CallKit entry
  or badge increment.
- Several aggregated events use counts only, never chat names.

The upstream notification-preview preference remains stored for data and
upstream compatibility, but XauXat rendering is fixed to hidden previews.

## Regression check

Run from the repository root:

```sh
./scripts/ios/verify-notification-privacy-policy.sh
```

This guard verifies the fixed hidden-preview mode, suppression before CallKit
selection and the generic CallKit display name. Physical lock-screen and
CallKit behaviour remains part of the two-iPhone acceptance matrix in issue
#79.
