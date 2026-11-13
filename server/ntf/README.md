# XauXat notification service

This deployment runs the SimpleX notification server pinned to the same protocol revision as the XauXat core. The server variant is published at [`eXsoria/simplexmq`](https://github.com/eXsoria/simplexmq/tree/c5184b72cdd48d9ecede01eff4f639f9d2b0f0f4). Its only source change makes the APNs bundle and Apple Team configurable at runtime instead of using the SimpleX Chat signing identity.

## First deployment

1. Point a dedicated DNS name at the host and allow inbound TCP 443 plus outbound TCP 443 to APNs and SimpleX relays.
2. Copy `.env.example` to `.env` and fill in the public host, APNs key ID and Apple Team ID.
3. Put the Apple `.p8` provider key at the path named by `APNS_KEY_FILE`. The `secrets/` directory and `.env` are ignored by Git.
4. Start the database and notification service:

   ```bash
   cd server/ntf
   docker compose up --build -d
   docker compose ps
   ```

5. Export the generated server identity and iOS build setting:

   ```bash
   ./print-app-setting.sh
   ```

6. Put the printed `XAUXAT_NTF_SERVER_B64 = ...` line in the developer-local `apps/ios/Local.xcconfig`. In CI, store only the base64 endpoint as a protected variable and pass it as the `XAUXAT_NTF_SERVER_B64` Xcode build setting. The endpoint contains a public server fingerprint, not an APNs credential.

The app deliberately configures no notification server when that setting is absent or invalid. It does not fall back to the SimpleX-operated notification servers.

## Credential rotation and revocation

Create a second Apple APNs key before revoking the current key. Replace the mounted `.p8` file atomically, update `APNS_KEY_ID`, and recreate only the `ntf` container. Confirm successful production pushes before revoking the old key in Apple Developer. If the new key fails, restore the previous file and key ID, recreate the container, then investigate without rotating the notification server fingerprint.

Treat the APNs `.p8` as a production secret. Restrict it to the service host and secret manager, never print it, never bake it into the image, and never upload it as a CI artefact. Apple Team ID and key ID are identifiers rather than private signing material, but they are still supplied through deployment configuration and omitted from normal logs.

## Recovery

Back up the `ntf-config` and `ntf-database` volumes using encrypted storage. The config volume contains the TLS identity whose fingerprint is embedded in the app endpoint. Losing it changes the server address and requires an app update. Restore both volumes together, mount a valid APNs key, and start PostgreSQL before the notification service.

If the service is unavailable, XauXat exposes the registration error and retries through its normal token reconciliation lifecycle. It does not connect directly to messaging relays as a substitute for the notification service.

## Privacy boundary

The SimpleX notification protocol gives the notification service a device token and independent notifier subscription identifiers. It does not receive the sender, contact, message body, or the recipient's SMP queue address. The APNs payload contains encrypted notification metadata for the device, not message content. The operator can still observe service timing, total notification volume, device-token lifecycle and the number of notifier subscriptions associated with a token; these operational metadata must be covered by the XauXat privacy policy and retention policy.

Before release, complete the physical-device matrix in issue #79 with a signed Release build and verify both sandbox and production APNs paths.

## Calls while Tor is unavailable

The current NTF container sends the existing SimpleX notification payload. The iOS extension still uses Tor to retrieve and classify that payload. A successful notification deployment therefore does not validate incoming calls while Tor is unavailable.

For the dedicated call channel, use the same VPS and APNs provider identity with a separate call notification path. The call service needs a device registration for that channel, bound to the recipient's authenticated call identity and revoked on sign-out or token invalidation. It must wake the device only for an authenticated, pending call invitation. Keep the APNs payload to an opaque call ID and expiry. Send the initial wake-up with the `voip` push type, the official bundle's `.voip` topic and a zero or short expiration. Retrieve and validate the encrypted invitation on the dedicated SMP channel. Send answer, cancellation and hang-up over SMP.

Before enabling this path in production:

1. Verify the signed app and extensions with `scripts/ios/verify-notification-configuration.py --app APP --require-configured --signed --production`.
2. Validate token registration, the official topic and the provider response against a real signed iPhone. Keep tokens and payloads out of server logs.
3. With Tor unavailable, test a call in each direction over mobile data. On the iPhone, test with the app open, in the background and with the screen locked. Verify CallKit reports the invitation, the call connects, and a cancelled or expired invitation clears without ringing again.
4. Confirm ordinary messages still use the Tor path and catch up after reconnecting.

The USB pairing in the current Debug build is a local test fixture. Release needs authenticated provisioning of dedicated call queues and the device registration and wake-up handlers above. The existing notification container has no call-specific trigger.
