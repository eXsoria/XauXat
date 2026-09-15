# Code-Locked Text on iOS

Code-Locked Text uses the common authenticated envelope without changing the
SimpleX transport or server protocol.

## Sender flow

- The bare lock control in the composer opens a protected code and confirmation
  form for Plus users.
- The code lives only in the active composer view. It is not written to drafts,
  preferences, logs, Keychain, or the outgoing message.
- Link previews, mentions, live messages, attachments, edits, forwards, and
  replies are excluded from this first text integration so none of their
  metadata can expose the clear message.
- Sending encrypts the message off the main UI path, transmits only the safe
  fallback and authenticated envelope, then clears the in-memory code.

## Recipient flow

- Tapping a protected message opens local code entry. Receiving and unlocking
  do not require a Plus subscription.
- A successful code check keeps the clear payload only in the local view
  session. The user must press and hold to preview it.
- Backgrounding, leaving the message view, screen recording, or releasing the
  preview hides the content.
- Invalid or truncated envelopes remain an opaque protected-message placeholder
  and never fall back to displaying their wire representation.

## Secondary surfaces

Chat-list previews, reply/forward context, message history, and notifications
show only “Protected message”. Copy, share, reply, edit, and forward actions are
not offered for a locked text item, including multi-select forwarding.
