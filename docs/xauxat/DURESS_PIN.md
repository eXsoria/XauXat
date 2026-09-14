# Duress PIN on iOS

The Duress PIN is a XauXat Plus app-lock action. It is distinct from the primary and decoy PINs and is evaluated only on the app unlock screen.

## User-selected scope

Before creating the PIN, the user selects one of the available scopes:

- Main environment
- Decoy environment, when configured
- Both environments, when a decoy environment is configured

The selected scope is stored as a non-secret preference. PINs and database keys remain in the iOS Keychain.

## Cryptographic destruction

When the Duress PIN is entered, XauXat does not show a confirmation. It closes the active SimpleX controller and removes the random Keychain database key for every selected environment before attempting to delete its encrypted database and files. File deletion is defense in depth; destruction of the encryption key is the security boundary.

The app then creates an ordinary empty replacement profile. For a decoy-only action, the Duress PIN becomes the PIN of the replacement decoy environment and the primary environment remains available through its original PIN. For main or both scopes, the Duress PIN becomes the new primary app PIN.

## Irreversibility

The setup warning states that the action cannot be undone, that it occurs without confirmation at unlock, and that XauXat does not create automatic iCloud backups. A separate user-created export is the only possible independent copy.
