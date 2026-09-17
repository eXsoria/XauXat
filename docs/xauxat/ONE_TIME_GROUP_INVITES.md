# One-time group invites on iOS

XauXat implements a one-time group invite by composing two existing SimpleX operations:

1. The group admin creates a SimpleX one-time contact invitation.
2. The SimpleX core accepts only the first valid connection for that invitation.
3. Once that contact is connected, XauXat sends the contact an invitation to the selected group and marks the one-time group invite as consumed.

This keeps the single-use decision in the SimpleX core instead of relying on a UI-only counter. Concurrent attempts therefore cannot create more than one accepted contact from the shared link.

The local policy is stored in the device Keychain and contains the target group, initial member role, connection identifier and lifecycle state. Admins can see whether an invite is active, processing, consumed, revoked, expired or needs attention. Failed group delivery can be retried for the same accepted contact without making the public link reusable.

When a group already uses XauXat access-code protection, the one-time SimpleX invitation is encrypted with the same code before it is shared. The code is never embedded in the protected URL. The policy already carries an optional expiry field so configurable expiry can be layered on without replacing the atomic one-time mechanism.

Revoking an unused invite deletes its pending SimpleX contact connection. Losing Plus access revokes all still-active one-time invites and removes their local policies; existing groups and members are not deleted.
