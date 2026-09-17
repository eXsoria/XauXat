# iOS notification acceptance matrix

Issue #79 is the physical-device release gate for XauXat notifications. It is
not satisfied by a simulator, a successful APNs request or an app process that
stays alive. Every P0 scenario in the machine-readable matrix must pass on two
current physical iPhones.

## Test artifact

The canonical template is
[`ios-notification-test-matrix.json`](ios-notification-test-matrix.json). Before
a test run:

1. Create a branch dedicated to the acceptance run.
2. Replace every `TODO` build and device field with the exact tested values.
3. Use the XauXat commit installed on both phones. Record the notification
   server revision independently.
4. Run every scenario on both devices. Set each result to `PASS`, `FAIL` or
   `BLOCKED`; do not delete a scenario that cannot be completed.
5. Add a short evidence reference for every result. Evidence may be a private
   artifact identifier rather than a public URL.
6. Run the strict validator and attach its output to the issue:

   ```sh
   ./scripts/ios/validate-notification-matrix.sh \
     --require-complete \
     docs/xauxat/ios-notification-test-matrix.json
   ```

The checked-in template intentionally remains `PENDING` until the physical run
is performed. CI validates its schema and coverage with:

```sh
./scripts/ios/validate-notification-matrix.sh \
  --allow-pending \
  docs/xauxat/ios-notification-test-matrix.json
```

## Pass criteria

A scenario passes only when its functional result and every listed privacy
expectation pass. In particular:

- banners never show a contact name or message content;
- hidden chats and protected profiles create no banner, sound, CallKit entry or
  badge change;
- tapping cannot bypass a conversation lock or protected-profile gate;
- changing or renewing the APNs token does not retain the obsolete token;
- notification-server loss fails safely and later recovers;
- Tor failure never creates a direct SMP or XFTP relay connection;
- packet capture covers the extension route as described in
  [`NSE_TOR_VERIFICATION.md`](NSE_TOR_VERIFICATION.md).

Any `FAIL` must become its own GitHub issue with the tested commit, device/iOS,
scenario ID, expected result, actual result and redacted evidence. Any
`BLOCKED` needs the external dependency and owner recorded before the
notification epic can close.

## Handling evidence

Screen recordings, unified logs and packet captures can contain network or
account metadata. Store originals in the restricted release evidence location.
The public matrix should reference an opaque artifact ID and contain no APNs
token, notification payload, contact name, message text, invite secret, relay
credential or stable user/contact identifier.
