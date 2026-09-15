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

The text representation starts with a plain compatibility notice followed by
the versioned envelope marker. A client without XauXat support sees only a safe
notice and encrypted data, never the protected content.

## Local state

`XauXatCodeLockedSession` owns the recipient-side state machine: locked,
unlocking, unlocked, or rejected. Verification and the unlocked payload stay in
the local app process. Locking invalidates an in-flight verification result and
immediately drops the clear payload from the session state.

Attempt limits and destruction policy build on the local rejection count in
their dedicated roadmap issues.
