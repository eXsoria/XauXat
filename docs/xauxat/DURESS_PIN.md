# Duress PIN / kill switch on iOS

The Duress PIN is a XauXat Plus app-lock action, distinct from the main and
decoy PINs. Setup requires a decoy PIN. It is evaluated only at app unlock,
without another confirmation.

## Result of entering the PIN

1. Stop the app's controller and wait for the notification extension to suspend.
2. Preserve the current decoy profile, conversations, attachments, encryption
   key, expression-library keys and per-profile protection/invitation policies.
3. Permanently remove the old main environment's database key and delete its
   databases, SQLite sidecars and local files.
4. Promote the existing decoy to the main role. The entered Duress PIN becomes
   the main app PIN; the old main PIN no longer unlocks an environment.
5. Create a separate empty decoy with its own ordinary profile and random
   database key. The existing decoy PIN opens this new environment.
6. Turn the Duress PIN setting **off** and remove its active PIN configuration.
   The new main PIN is an ordinary unlock until the user explicitly arms a new,
   distinct Duress PIN in Settings.

The old selector for main/decoy/both destruction and the replacement-main name
field no longer apply. The decoy's existing name is retained when it becomes
main. The replacement decoy uses the configured decoy display name.

An older installation with a Duress PIN but no decoy first creates an ordinary
decoy before deleting any main data. In this compatibility case the former main
PIN opens the empty replacement decoy.

## Storage and interruption recovery

Logical primary/decoy roles resolve to independent physical directories and
Keychain namespaces. Promotion atomically updates one Keychain role record
instead of moving a live database or copying secrets one at a time. Existing
installations retain their original paths until the first promotion; each new
decoy receives a fresh UUID namespace, including attempt counters and policy
keys. Extension processes use the same role record and discard a cached native
controller when its database path no longer matches the primary role.

A Keychain journal is written before erasure. If persistence is interrupted,
the next launch suspends the notification extension and resumes the pending
promotion before permitting native-store initialization. Resumption after an
already committed role change cannot erase the promoted main. Failed key
deletion prevents file deletion and role changes. An error during fresh-decoy
creation does not authenticate or show the wrong profile; the promoted main
remains intact and the normal decoy-unlock path can finish empty-profile setup.

The separate **Destroy data after 3 failed PINs** policy retains its all-store
destruction behavior. It does not promote the decoy.

## Validation

`bash scripts/ios/test-kill-switch.sh` compiles production Keychain role routing,
storage paths, deletion and unlock orchestration with injectable OS/native
services. It checks populated decoy preservation, independent empty replacements,
PIN changes, settings reset, repeated promotion, legacy document storage,
extension-suspension refusal and interrupted Keychain commits/cleanup.

Physical iPhone testing is still required for native SQLCipher opening and
actual notification-extension suspension. Cryptographic deletion cannot remove
a separate export the user created earlier. XauXat makes no automatic iCloud
backup of live app data.
