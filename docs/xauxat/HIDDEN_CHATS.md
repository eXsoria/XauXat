# Hidden conversations on iOS

Hidden conversations are a local XauXat Plus presentation layer over the
existing SimpleX chat data. Hiding a conversation does not delete or mutate its
messages, contact, group, or protocol state.

## Behaviour

- Direct and group conversations can be hidden from their information screen.
- The normal XauXat and legacy chat lists omit hidden conversations.
- Contact search, forwarding destinations, new-chat contact lists, and the iOS
  Share Extension omit hidden conversations.
- Opening a hidden conversation through an indirect route still requires the
  authentication policy selected in App Lock.
- Local and Notification Service Extension message notifications are suppressed
  for hidden conversations. CallKit uses a generic XauXat identity, and hidden
  activity does not increment the app badge.
- App and active-profile unread badges exclude hidden conversations.
- Hiding a conversation clears delivered notifications and immediately closes
  that conversation if it is open.

## Discovery and recovery

Privacy & Security contains the only normal entry point to the hidden list.
Opening it requires App Lock authentication. From there, a conversation can be
shown again without data loss. This recovery entry remains available for
already-hidden conversations if the Plus subscription later expires.

## Storage isolation

Only opaque local chat IDs are stored in the iOS Keychain. Primary and decoy
databases use separate Keychain items. Their hidden-chat metadata is removed
with the corresponding local database during reinstall cleanup, decoy removal,
or duress destruction.
