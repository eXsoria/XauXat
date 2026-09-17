# Expiring group access on iOS

XauXat Plus admins can set protected and one-time group access to never expire, expire after 15 minutes, 1 hour, 24 hours or 7 days, or use a custom date. The selected policy and exact date are shown before sharing.

Protected group links use version 2 of the XauXat encrypted envelope. The link and expiry are encrypted together and authenticated with ChaChaPoly, so changing the expiry invalidates the envelope. A recipient with the correct code still receives `Expired` after the deadline. Once an expired envelope has been observed, a Keychain tombstone prevents clock rollback from making that same envelope usable again. Version 1 non-expiring links remain readable.

One-time group access uses the same encrypted envelope when a code is enabled. Without a code, XauXat wraps the one-time SimpleX invitation in the signed expiring contact-invite envelope, so expiry can still be checked on the recipient before connection.

At the deadline the sender app deletes the underlying protected group link or pending one-time SimpleX connection. If the device is offline, the authenticated public envelope already rejects access and cleanup is retried after connectivity returns. Admins can revoke either kind of access before its deadline.

The expiry field is part of the same local policy used by one-time access and is designed to remain in the policy when maximum-use access is added.
