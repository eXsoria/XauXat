# Code-Locked Content envelope on iOS

The XauXat iOS client has a versioned, authenticated envelope for protected
text and media. It is implemented above the unchanged SimpleX transport and
therefore does not require a server or protocol fork.

## Cryptography

- The user code is normalized locally and is never stored in the envelope or
  sent to the recipient.
- PBKDF2-HMAC-SHA256 derives a 256-bit key from the code, a fresh 128-bit random
  salt, and 210,000 iterations.
- ChaCha20-Poly1305 encrypts and authenticates the complete payload.
- The envelope version, content kind, KDF, and iteration count are bound as
  authenticated data. Changing any of them makes decryption fail.
- File names and MIME types are inside the encrypted payload rather than in the
  visible envelope.

## Payloads and transport

The common payload supports text, image, audio, video, and file data. Small
payloads can use the text wire representation. Larger media can store the same
encoded envelope as the transferred file in the dedicated media integrations.

Protected videos use the media-file representation. The public SimpleX video
message contains only a neutral lock poster, a zero duration and a protected
content marker. The MP4 bytes, real duration, MIME type and optional caption
are authenticated and encrypted inside the envelope. After a correct code, the
viewer writes the clear MP4 to a protected temporary file only while the user
holds the preview. Releasing it, backgrounding XauXat, screen capture, or
leaving the view pauses playback and removes that temporary file. The standard
video gallery and share/save actions never receive the protected video URL. A
launch-time sweep removes a protected-video temporary file left behind by an
unexpected process termination.

Protected documents use the same media-file representation and common
authenticated envelope. The public SimpleX file carries only a generated
`.xauxat` name and a protected-file marker. The original file name, extension,
MIME type, bytes, and optional caption remain inside the encrypted payload.
The recipient sees no name or document preview before entering the correct
code. After unlock, XauXat materializes a randomly named, file-protected copy
only for its read-only in-app Quick Look surface. That surface has no share or
editing controls and is kept separate from the standard file Share Sheet.
Closing the preview, locking or backgrounding the app, screen capture, leaving
the chat, and the launch-time stale-file sweep all remove the clear temporary
copy.

The text representation starts with a plain compatibility notice followed by
the versioned envelope marker. A client without XauXat support sees only a safe
notice and encrypted data, never the protected content.

## Local state

`XauXatCodeLockedSession` owns the recipient-side state machine: locked,
unlocking, unlocked, or rejected. Verification and the unlocked payload stay in
the local app process. Locking invalidates an in-flight verification result and
immediately drops the clear payload from the session state.

The sender can authenticate a maximum of 1 to 20 attempts in the envelope, or
explicitly allow unlimited attempts. Failed attempts are keyed to the exact
encrypted envelope and stored in the device Keychain, so closing or restarting
XauXat, deleting and receiving the same message again, or reinstalling the app
does not trivially reset the counter. The unlock sheet shows the remaining
count and the session refuses further code checks at zero.

The sender can also bind a destruction policy to a finite attempt limit. On the
final failed attempt, the official XauXat client stores a durable Keychain
tombstone for that exact envelope and permanently refuses to derive its key or
materialize its payload on that device. See
`CODE_LOCKED_AUTO_DESTRUCTION.md` for the lifecycle and threat boundary.
