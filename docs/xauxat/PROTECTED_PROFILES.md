# Protected profiles on iOS

XauXat uses the existing SimpleX profile-password mechanism instead of storing
a parallel profile secret. The SimpleX core keeps each identity's chats and
settings separated and requires the profile password when activating a
protected identity.

## Behaviour

- Protecting a profile is available only with an active XauXat Plus entitlement.
- The profile password is entered and confirmed before protection is enabled.
- A protected profile is absent from ordinary profile lists and can only be
  revealed by entering its full password in Protected profiles.
- If the protected profile is active, XauXat switches to another visible
  profile immediately so the protected name and avatar do not remain in the
  normal UI.
- Existing protected profiles can still be revealed and unprotected after a
  Plus subscription expires.
- Profile protection does not copy chats or create another local database. It
  retains the identity separation already enforced by the SimpleX core.

## Notification and navigation privacy

- Local and Notification Service Extension events for a protected inactive
  profile are suppressed and do not increment the app badge.
- CallKit uses a generic XauXat caller identity for a protected profile.
- Notification responses cannot automatically activate a protected profile.
- Other activation paths still pass no profile password and are rejected by the
  SimpleX core; only the authenticated Protected profiles flow supplies it.

The app mirrors only the numeric IDs of protected profiles into a per-storage
Keychain item so the notification extension can suppress events that contain a
minimal `UserRef` rather than the full profile. No profile password or profile
content is duplicated. Primary and decoy stores use separate mirror items.
