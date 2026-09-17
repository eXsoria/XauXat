# Invalidate group link and code after entry on iOS

The atomic "invalidate after entry" policy is implemented through XauXat one-time group access. The public payload contains a SimpleX one-time contact invitation instead of a reusable group link, so the core decides the single winner when attempts race.

As soon as the winning connection arrives, XauXat commits a local `processing` state and removes both the share link and clear access code from the Keychain record before it attempts the network operation that sends the group invitation. The consumed SimpleX invitation cannot accept a second connection.

If group delivery succeeds, the admin sees `Consumed` and a final "Link and code invalidated" state. If network delivery fails, the admin sees `Needs attention` and can retry delivery to the already selected contact. Retrying never restores the public link or code. A delivery left in `processing` by app termination becomes an explicit retryable failure after two minutes.

Revoking before use deletes the pending SimpleX connection first. The local state changes to `Revoked` and erases the link and code only after that operation succeeds, so a network failure does not pretend the access was revoked.
