# XauXat iOS backup policy

XauXat does not allow iOS or iCloud device backups to copy its live private
storage. At every launch and after database initialization or restoration, the
app marks its private storage container with `isExcludedFromBackup = true` and
verifies that the resource value was applied.

The excluded storage contains:

- the encrypted chat and agent databases;
- locally stored sent and received media;
- preferences shared with the notification and share extensions;
- wallpapers and temporary migration data;
- the embedded Tor data directory.

Files remain encrypted locally according to the existing SimpleX storage
settings. Backup exclusion is an additional boundary, not a replacement for
local encryption.

## User-initiated exports

Database export remains available under the retained SimpleX implementation.
The user chooses an external destination through the iOS document picker. That
explicit export is outside XauXat's private app container and is therefore not
silently recreated or uploaded by XauXat.

## Release verification

Before a signed TestFlight build is promoted:

1. Create a profile and exchange a text message, image and file.
2. Confirm that the app-group container and Tor data directory report
   `NSURLIsExcludedFromBackupKey = true` on a physical iPhone.
3. Run an encrypted Finder device backup and verify that the live XauXat
   database and media directories are absent from the extracted application
   backup.
4. Export the database manually and verify that the exported archive remains
   usable when the user explicitly saves it.

Apple documents the resource value and notes that file operations can reset it,
which is why XauXat reapplies the policy during storage initialization:

- <https://developer.apple.com/documentation/foundation/urlresourcevalues/isexcludedfrombackup>
- <https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup>
