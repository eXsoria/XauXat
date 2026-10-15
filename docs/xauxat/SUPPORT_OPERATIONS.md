# XauXat support and reports

## Architecture and current state

XauXat uses the same documented model as the SimpleX team: an in-app business contact, backed by a continuously running CLI profile on a cloud VM. Operators use its private SSH console or connect SimpleX Desktop to that CLI profile. See [SimpleX for business](https://simplex.chat/docs/business.html).

The former HTTP ticket service was never enabled in production and has been removed from this PR. There is no support web form, ticket receipt, email intake, public WebSocket API, or separate HTTP report payload. The public support address resolves through the native chat protocol; its HTTPS spelling does not open a browser or upload a report over HTTP.

Public support contact:

`https://smp5.simplex.im/a#tduG95hbcB-06tBp5y9c4k8qPoNlrkNrR90wdZns-bY`

On 2026-10-15 the CLI profile and its business address were created on the existing DigitalOcean VPS. A separate synthetic native client connected, received the welcome message, sent a message to support, and received a manually sent reply. The service survived a stop/start with the same profile and address. The first encrypted backup was decrypted into an isolated directory and opened in maintenance mode without networking; the address and business settings were preserved. These checks do not replace iPhone/TestFlight validation or an operator handover.

## What reporting means

- **Group reports:** use the existing native report-message flow. The selected message/reason is shared with that group's moderators and owners under the native group-report permissions. It does not automatically reach XauXat support.
- **Direct contact or message reports:** selecting a reason opens an explanation, then the official support contact. No report has been sent at that stage. The user connects using the normal profile/incognito choice, writes their report in the encrypted support conversation, and explicitly sends it. Another contact's identity, selected message, media, full history, keys, and device tokens are not automatically attached or copied.
- **Block:** remains available separately and takes effect locally without requiring a report.
- **Replies and tracking:** appear in the same native conversation in Chats. There is no separate ticket secret to lose. Existing support conversations are opened using the native connection planner.

The support team is a recipient and can read what the user intentionally sends there, plus the name/avatar of the profile chosen when connecting. End-to-end encryption does not give support access to other private chats. Group reporting does not grant platform-wide decryption or the ability to ban an identity across the decentralized network.

## Host isolation

- Binary and launch scripts: `/opt/xauxat-support-chat` (root-owned).
- Official upstream release asset: `v7.0.3`, `simplex-chat-ubuntu-22_04-x86_64`.
- SHA-256: `5afb1d25efe5ccf564a1ab124bc7f410a7a73171c974a4d8b7f4d8f2e3d62e77`.
- The asset reports `SimpleX Chat v7.0.0.12`; record the release tag and digest as well as its own version output.
- Profile: `/var/lib/xauxat-support-chat`, owned by dedicated OS user `xauxat-support`, directory mode `0700`, databases `0600`.
- Unit: `xauxat-support-chat.service`, enabled; restart policy `always`, CPU quota 25%, memory high 256 MiB / maximum 384 MiB, no capabilities, restricted writable paths.
- The CLI runs in a private tmux session; `/run/xauxat-support-chat/operator.sock` is protected by a `0700` runtime directory.
- No new inbound ports or public API. Existing Baraoteam and NTF containers/routes remain unchanged.
- The support recipient uses upstream native private message routing on the VPS. It does not run a Tor client. The mobile app continues to use its managed Tor path to SMP/XFTP; the CLI recipient's network configuration is separate from that policy.
- Received media/files are not automatically accepted by a support bot; there is no bot configured. Operators decide what to receive using the native client.

Encryption in transit terminates at the authorized support profile. Its live databases are not configured with a SQLCipher passphrase; filesystem access is restricted to its OS user and root. Do not describe this as an encrypted-at-rest live database. Do not publish database files, tmux captures, profile exports, or recovery keys in CI/issues.

## Deployment and upgrades

The service source files are in `services/support-chat/`. A fresh host needs Ubuntu 22.04 x86_64, tmux, curl, GnuPG, and a dedicated non-login/system user with its home at `/var/lib/xauxat-support-chat`. Create private `files` and `tmp` directories there. Download the pinned upstream release asset over HTTPS and verify its SHA-256 before installing it as `bin/simplex-chat`; do not execute a remote installation script blindly.

Install `run.sh`, `start.sh`, and `backup.sh` root-owned as mode `0755` in `/opt/xauxat-support-chat`, and the service/timer files as `0644` in `/etc/systemd/system`. Generate a new random backup passphrase into `/etc/xauxat-support-chat/backup.key`, root-owned `0600`, without printing it. Never replace an existing profile or recovery key during redeployment. Reload systemd, enable/start the chat service and backup timer.

The initial profile is created by `--user-display-name XauXatSupport`. In its private console:

```text
/ad
/auto_accept on business text Welcome to XauXat support. This conversation is end-to-end encrypted with the support team. Describe your question or report and share only the specific information you choose. Never send passwords, recovery keys or full chat histories. Replies are handled by a person; this is not an emergency service.
/ttl month
/sa
```

`/ad` is only for the initial address creation. Do not delete/recreate the production address to change its auto-accept settings: shipped clients must retain a working recipient. Never use `/simplex` as the XauXat support destination; it connects to the upstream team.

The public short address is base64-encoded in `XAUXAT_SUPPORT_CONTACT_B64` in Debug/Release xcconfig and injected into `XauXatSupportContactB64` in the app Info.plist. Base64 avoids xcconfig comment parsing, not secrecy. The app accepts only native short contact links in this setting and passes them to `planAndConnect`. Changing the configured endpoint requires validation and a new build.

Before upgrading, run and restore-test a backup. Pin/verify the new upstream binary, stop the service, replace only the binary, then start and validate the existing contact and an existing conversation. Database migrations can be irreversible: rollback includes restoring the matching databases while the service is stopped. Never run two live networked copies of one profile.

## Operator access

In an authenticated SSH session:

```sh
sudo -u xauxat-support tmux -S /run/xauxat-support-chat/operator.sock attach -t support
```

Detach with Ctrl+B, then D. Do not quit the CLI when leaving. Native commands include `/chats`, `/tail #CHAT`, and `#CHAT message text`; use the actual native chat name shown by the console. Do not copy user messages to terminal logs or public issue trackers.

For the same Desktop operator experience documented by SimpleX:

1. Install/open the official SimpleX Desktop app on Windows and enable Developer tools.
2. Choose Linked mobile â†’ Link a mobile, address `127.0.0.1`, fixed port such as `12345`, and copy its pairing link.
3. Establish an authenticated SSH reverse tunnel to loopback only. With PuTTY, add remote forwarding `R12345 -> 127.0.0.1:12345` and keep the SSH session open. Keep remote ports bound to loopback; do not enable GatewayPorts or expose the controller publicly.
4. In the VPS CLI enter `/crc LINK`, using the Desktop link. Compare the verification code displayed on both sides and enter the full `/verify remote ctrl ...` command shown by the CLI only after matching it.
5. Use Desktop to read/respond to the same VPS profile. Operators take turns; pairing does not create independently synchronized copies of the database.

Desktop pairing and the first human operator response remain part of handover. CLI access already allows an authenticated operator to reply. Do not claim the inbox is monitored 24/7 or give a response-time promise until staffing is agreed.

## Retention, backups, deletion and escalation

The native profile has `/ttl month`: chat items are automatically deleted after 30 days according to native retention, rather than 30 days after the latest ticket activity. Contact/group records persist until explicitly deleted. Retention does not remotely guarantee deletion of a user's copy or material another recipient already saved.

A daily timer runs an offline, consistent backup of both databases and selected profile files. It briefly stops only the support CLI, encrypts the tar stream with AES-256 via GnuPG using the root-only recovery key, and restarts the CLI even on failure. No plaintext archive is written. Local encrypted archives in `/var/backups/xauxat-support-chat` are rotated after 7 days; deleted messages can therefore remain in backups for up to 7 additional days. Exclude synthetic validation databases and temporary files. Operators must delete any manually downloaded attachments when resolving/deleting a conversation; the chat item TTL alone is not an audit of every manually saved copy.

The live backup and key on the same VPS do not constitute off-host disaster recovery. The first encrypted archive and its separate recovery-key file were also copied to an ACL-restricted owner directory on Windows, outside this repository. Recurring off-host transfer is not configured. Keep current encrypted archives off-host and protect the recovery key separately; never commit either. A restore procedure:

1. Stop the live profile; do not start another networked copy alongside it.
2. Decrypt the archive into a private directory and verify its contents/ownership. Use the recovery key through `--passphrase-file`, never in an argument or shell history.
3. For an offline drill, open the restored databases with `--maintenance --execute /sa --execute-log all --time 1` and confirm the same address/business settings. This mode must not start chat networking.
4. For actual recovery, replace the stopped profile with the verified restore, preserve `xauxat-support` ownership and private modes, start the one live service, and test sending/replying using a separate owned client.

Read new conversations, ask only for information needed, and reply in the same chat. Acknowledge the report, explain the available local/group moderation action and keep follow-up in that thread. Do not request encryption keys, complete chat exports, payment credentials, or unnecessary identity documents. For a deletion request, delete the relevant conversation and any manually saved attachments; explain the bounded encrypted backup window. For group incidents, moderators handle native group reports. XauXat can moderate its own groups/services where it has the relevant role; it cannot remove arbitrary content from somebody else's encrypted private chat or block files on third-party XFTP hosts.

## Verification and release gate

Already verified on the VPS, 2026-10-15:

- Dedicated profile, enabled service, private modes and resource limits; no new public listener.
- Native business auto-accept, welcome message, synthetic message and support reply received.
- Profile/address persisted across service stop/start; subscriptions restored.
- Encrypted backup creation and offline restore with the same address and business settings.

Automated checks in this PR cover build-setting destination safety, absence of the old HTTP submission boundary, actual Swift model cases, and iOS 15 support UI type checking. The full iOS workflow builds the real app against the real native core. CI/simulator results are not evidence of APNs delivery or a human-operated support inbox.

Before marking support complete:

- A green full iOS build for the final PR head.
- A TestFlight build containing the final native support contact.
- Two iPhones: open support through Settings and Help; connect using the chosen profile; send a request; receive a human reply; close/reopen and return to the same conversation.
- A direct-contact/content Report action opens the explanation without automatically sending anything; Block still works independently.
- A group report reaches moderators and does not reach support automatically.
- Offline/Tor unavailable, recovery, existing-chat navigation, hidden/incognito profile choice and app restart behave like ordinary native chats.
- An owner demonstrates operator access/response, and off-host recovery materials are handed over privately.

The support PR remains a draft until the implementation and validation gates are reviewed. Updating GitHub issue acceptance to the native conversation model must not assert that a web ticket number or centralized cross-network ban exists.
