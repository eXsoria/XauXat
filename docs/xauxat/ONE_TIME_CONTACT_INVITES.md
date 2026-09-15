# One-time contact invites on iOS

XauXat Plus exposes the SimpleX protocol's native one-time invitation links.
The app does not replace them with a reusable contact address or add a separate
XauXat server.

## Behaviour

- The first successful join consumes the invitation queue in the SimpleX
  protocol. A second or racing join cannot establish another contact from the
  same invitation.
- The existing SimpleX invitation lock serializes simultaneous attempts in one
  client, while the protocol invitation itself remains single-use across
  clients.
- While an invitation is pending, its details show **Invite status: Unused**.
- Once the pending connection becomes a contact, the creator's contact details
  show **One-time invite - Status: Used**. The original link is no longer
  exposed.
- Deleting the pending connection keeps the existing pre-use revocation flow.

## Plus boundary

Every iOS entry point keeps **Create 1-time link** visible. Free users see it as
locked and are taken to XauXat Plus; entitlement is checked again before the
core creation command can run. Local Debug builds retain their existing
automatic Plus access.

Only the iOS presentation and entitlement boundary change here. The underlying
SimpleX one-time invite, atomic consumption, pending-connection deletion, and
contact creation logic are preserved.
