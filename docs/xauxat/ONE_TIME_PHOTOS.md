# XauXat one-time photos on the SimpleX protocol

XauXat sends one-time photos as the versioned `xauxat.image` message content
type. The policy travels inside the authenticated end-to-end encrypted SimpleX
message and does not depend on a file name:

- `version`: policy schema version, currently `1`;
- `viewOnce`: must be `true` for version 1;
- `allowSave`: whether the receiving XauXat client exposes a save action;
- `fileCrypto`: the key and nonce for the additional local file envelope.

The photo is sanitized before sending and then encrypted once more at the app
layer. SimpleX transfers the resulting `.xauxat` envelope as an opaque file.
The app-layer key is only present inside the E2EE message, so a client that does
not understand `xauxat.image` cannot silently treat the attachment as a normal
photo. It can still show the explicit fallback text `One-time photo - open with
XauXat`.

On a receiving XauXat client, opening the photo records consumption in local
persistent state. Closing the viewer removes the local encrypted envelope. The
sender's `allowSave` policy controls whether the save action is shown.

The composer enables One-Time View by default and exposes it as a real toggle.
Turning it off sends a regular SimpleX image. Sent one-time photos remain visible
to their sender, but carry a clear One-Time View marker in the chat bubble.

## Compatibility

Photos created by the initial iOS implementation used `xauxat-otv-ns-` or
`xauxat-otv-as-` file-name prefixes. XauXat continues to recognize those names
for migration, but new messages never rely on them for policy.

## Security boundary

One-time viewing and `allowSave` are cooperative client controls, not DRM. A
modified recipient client can retain decrypted pixels, photograph the screen
with another device or ignore consumption. XauXat adds screen-capture and app
switcher protections on supported iOS paths, but does not claim that a sender
can control a recipient's device absolutely.

The additional envelope provides safe degradation for current unsupported
SimpleX clients, not permanent forward secrecy after viewing. A recipient who
already possesses the authenticated message and deliberately modifies their
client may keep the key or ciphertext. Release messaging must describe this as
privacy against accidental retention and compliant clients only.
