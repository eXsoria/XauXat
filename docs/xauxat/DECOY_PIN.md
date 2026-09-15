# Decoy PIN on iOS

The Decoy PIN is a XauXat Plus feature built on top of the existing app lock. It is available only when app lock uses a PIN.

## Storage separation

- The primary and decoy environments use different encrypted SimpleX chat and agent databases.
- Each environment has its own random database key in the iOS Keychain.
- Received files, temporary files, migration files and wallpapers use separate directories.
- The decoy directory is excluded from device and iCloud backups under the same XauXat policy as the primary store.
- The native SimpleX core has one active controller at a time. Switching environments stops and closes the current controller, clears visible chat state, selects the other storage scope, then initializes a new controller.

## Unlock behavior

- The primary PIN opens the primary environment.
- The decoy PIN opens the decoy environment and creates its ordinary local profile on first use.
- The app starts with no remembered decoy selection. After a restart, the entered PIN selects the environment again.
- While a decoy PIN exists, app unlock always uses PIN entry. Face ID, Touch ID and the device passcode cannot bypass environment selection.
- The decoy environment does not show its own setup or removal controls.

Removing the decoy environment requires primary-environment authentication and deletes only its separate databases, keys and local files.
