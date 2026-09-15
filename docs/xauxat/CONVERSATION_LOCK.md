# Conversation lock on iOS

Conversation lock is a XauXat Plus feature that adds authentication on top of selected local conversations without changing the SimpleX protocol or remote data.

## Enforcement

- Locked chat IDs are stored per primary/decoy environment in the iOS Keychain.
- Every primary chat-opening path passes through `ItemsModel`, including notification navigation and indirect internal links.
- Opening a locked conversation invokes the authentication policy selected under App Lock: system authentication or the XauXat app PIN.
- The XauXat list replaces the latest-message preview with `Locked conversation`.
- Locked direct chats are excluded from contact search.
- Forwarding and the iOS share extension exclude locked destinations so they cannot be used without opening and authenticating first.
- Message, connection and call notifications omit the conversation identity and message/call detail.

Lock and unlock actions both require authentication. Locking an open conversation immediately closes it. Existing locks remain enforceable and removable if a Plus subscription later expires; only creating a new lock requires an active entitlement.
