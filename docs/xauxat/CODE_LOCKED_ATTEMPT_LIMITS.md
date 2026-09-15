# Code-Locked attempt limits on iOS

The sender can choose 3, 5, 10, or unlimited code attempts when protecting any
supported content type. The common envelope also validates any programmatic
finite value against the supported range of 1 through 20 before encryption.

## Authentication and compatibility

`maxAttempts` is part of the envelope and its value is included in the
ChaCha20-Poly1305 authenticated data. Modifying or removing a finite limit makes
the payload fail authentication. Existing version 1 envelopes without the
optional field keep their original authenticated header and remain unlimited,
so previously sent protected content remains readable.

## Recipient state

- A SHA-256 identifier derived from the complete encrypted envelope separates
  counters for different messages without storing their clear content.
- Each failed verification is synchronously persisted in the iOS Keychain for
  the active XauXat identity before the UI reports the result.
- Recreating the view or restarting the app reloads the counter. Keychain
  persistence also prevents a normal reinstall from being an easy reset on a
  physical device.
- The unlock form shows the remaining count. At zero, input is disabled and all
  protected-content views show a terminal no-attempts state.
- A successful verification removes the failure counter for that envelope.

This issue blocks additional attempts but does not delete the encrypted message.
Cryptographic auto-destruction at the limit belongs to the next roadmap issue.
