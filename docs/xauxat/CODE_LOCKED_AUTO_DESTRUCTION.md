# Code-locked content auto-destruction on iOS

XauXat Plus lets the sender require the recipient's official iOS client to
destroy local access to protected content after the final failed code attempt.
The policy is selected before sending and authenticated inside the encrypted
envelope, so it cannot be silently removed or changed in transit.

## Behaviour

- Auto-destruction is available only with a finite maximum-attempt limit.
- Every failed attempt is stored in the iOS Keychain for the exact encrypted
  envelope and the current local XauXat identity.
- On the final failure, XauXat replaces the attempt state with a durable
  destruction tombstone and moves the session to `destroyed`.
- A destroyed envelope is never passed to the key-derivation or decryption
  path again. Recreating the SwiftUI view or restarting XauXat keeps the
  destroyed state.
- Text, photo, audio, video, and document views show only `Content destroyed`.
  No preview, playable media, or clear temporary file is created.
- The existing protected-content rules continue to block reply, forwarding,
  sharing, and saving through the normal chat menus.

The Keychain write is fail-closed. If iOS does not persist the destruction
tombstone, XauXat keeps the content exhausted and still refuses further unlock
attempts instead of reporting a successful destruction.

## Clear-data lifecycle

A failed unlock never produces clear content. Protected video and document
temporary files can only be created after a successful unlock and are already
removed when their preview closes, the app backgrounds, capture starts, or the
view disappears. The launch sweep removes stale protected temporary files left
by an unexpected termination.

## Threat boundary

This feature permanently removes access in the official XauXat client on that
recipient device. It cannot make ciphertext that has already been delivered to
a hostile or modified recipient client disappear remotely. Such a client could
copy the encrypted envelope before enforcing the policy. XauXat therefore does
not describe this as remote deletion or as protection against a recipient who
controls a modified client.
