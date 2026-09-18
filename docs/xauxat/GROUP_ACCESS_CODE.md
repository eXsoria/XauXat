# XauXat Plus group access code (iOS)

Protected group access keeps the SimpleX group link encrypted inside a XauXat invite. The admin shares the generated access code separately.

## Security model

- XauXat generates a 12-character code from a 32-character unambiguous alphabet, providing 60 bits of random entropy.
- The code is normalized locally, processed with PBKDF2-HMAC-SHA256 at 310,000 iterations and used to decrypt an authenticated ChaCha20-Poly1305 envelope.
- The protected URL contains the salt, KDF parameters and encrypted SimpleX link. It never contains the access code or the clear SimpleX link.
- A protected URL by itself cannot create a SimpleX join request. The iOS app asks for the separately shared code before it can recover and pass the original link to the unchanged SimpleX connection flow.
- Failed attempts use an exponentially increasing 1-to-60-second delay. Attempt state is stored in the device Keychain and survives app restarts.

## Admission and revocation

- Enabling protection first deletes the previous SimpleX group link and creates a fresh one. An unprotected link copied before activation therefore cannot bypass the access code.
- Protected private-group links keep XauXat reviewed admission enabled. Correctly unlocking the invite only creates the normal pending request; an admin still approves membership.
- `Revoke link and code` deletes the underlying SimpleX group link. Previously shared encrypted envelopes may still be copied, but decrypt to a link that the SimpleX servers no longer accept.
- Existing members remain connected after revocation.
- When Plus access ends, XauXat revokes protected group links and removes their local access-code policies. It does not delete groups or members.

## Compatibility

The encryption and access-code layer is implemented in the iOS fork. The SimpleX protocol and servers are unchanged. A recipient needs XauXat support for the protected envelope; ordinary SimpleX links continue to work unchanged when protection is not enabled.
