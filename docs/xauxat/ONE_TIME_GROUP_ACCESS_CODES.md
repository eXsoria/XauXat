# One-time group access codes on iOS

An admin can add a unique one-time access code when creating a one-time group invite. XauXat generates a new 60-bit code locally and encrypts the underlying SimpleX one-time invitation with PBKDF2-HMAC-SHA256 and ChaChaPoly.

The code protects only that individual access. It is not the reusable code of the group's normal protected link, so consuming or revoking it does not rotate or delete the normal group link.

Successful redemption creates the single contact connection allowed by the SimpleX core. When XauXat receives that connection, it atomically marks the access as processing and erases the clear access code from the local Keychain record. Reopening the encrypted URL cannot create another connection because the underlying SimpleX invitation has already been consumed.

The admin UI keeps the non-secret lifecycle state and shows that the access used one-time code protection, but it displays the code only while the access is active. Revocation deletes the pending SimpleX connection and erases the code before it can be used.
