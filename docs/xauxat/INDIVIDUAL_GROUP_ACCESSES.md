# Individual group access batches on iOS

XauXat Plus group admins can generate a batch of individual accesses instead of one shared limited-use link. Every access has a random local identifier, its own SimpleX one-time invitation, its own share link, and, when enabled, its own access code.

The group access screen lists each active access separately with its identifier, status, expiry, share action, code-copy action, and revoke action. Sharing an item exports only that item's protected link. Its code is copied separately and no other access code is included.

Each record is stored locally in encrypted Keychain state with only access-management metadata. It does not contain message or conversation content. A batch identifier preserves their administrative relationship without making revocation collective.

Revoking one individual access deletes only its matching pending SimpleX connection. The remaining accesses in the same generated batch continue to work and retain their own state. Used, expired, failed, and revoked items remain individually identifiable in the local history.
