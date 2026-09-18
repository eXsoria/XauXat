# Maximum uses for group access on iOS

XauXat Plus group admins can create one shared access that accepts a chosen number of entries, up to the remaining capacity of the group. The screen shows the configured limit, consumed uses, and remaining uses.

Each allowed use is backed by a separate SimpleX one-time contact invitation. The shared XauXat envelope contains those authenticated invitations and the receiving app checks candidates until it finds one that is still available. Because the SimpleX core consumes each underlying invitation atomically, simultaneous connections cannot claim more slots than the configured limit.

Code protection encrypts the complete authenticated bundle instead of exposing its SimpleX invitations. Expiry is applied to both the outer protected envelope and the signed bundle. When the final invitation is claimed, every underlying access is consumed and the shared access can no longer create a connection.

Revocation deletes every still-available SimpleX invitation before removing the shared link and code from local Keychain state. Successful deletions are checkpointed so an interrupted revocation can continue safely without reactivating or losing track of the remaining access.
