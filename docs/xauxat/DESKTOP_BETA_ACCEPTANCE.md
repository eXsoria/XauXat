# Internal Desktop beta acceptance

This milestone covers iPhone remote access and operating the existing VPS support profile with XauXat Desktop. Use synthetic conversations and a test iPhone profile. The Desktop does not yet implement all XauXat iOS protected-content or Tor policies. Do not treat successful pairing as acceptance of those features.

## Package evidence

Use the artifact for the exact OS/CPU from the **XauXat Desktop** workflow on PR #169. Each artifact must include an installer, `SHA256SUMS.txt`, `BUILD-PROVENANCE.json` and `PACKAGED-SMOKE.json`. Check the installer digest before installation. The provenance records the actual source commit, built core and verified dependency versions; a green source-only job is insufficient.

These initial packages are unsigned/ad-hoc on macOS and not notarized. Linux initially targets Ubuntu 24.04 x86_64. Public download/distribution approval and production signing are separate release gates. Do not add personal profiles or support recovery material to artifacts or issue comments.

## Link a test iPhone

1. Open XauXat Desktop and select **Link a mobile**. Set a custom local database passphrase, separate from the phone's passcode, and leave passphrase saving disabled. The inherited Desktop implementation stores any saved/random passphrase as plaintext in its settings; it does not use an OS keychain. Verify the app asks for your passphrase after reopening, before pairing a live support profile.
2. Keep the iPhone and Desktop on the same trusted local Wi-Fi for the initial test. Allow XauXat local-network access on iOS and the Desktop application's local-network connection through the OS firewall. Do not forward this port on the router.
3. In the iPhone chat-list menu choose **Connect to desktop** and scan the Desktop pairing QR code. Compare the full pairing/verification code on both screens before accepting.
4. Keep the phone online and XauXat open during the first test. The Desktop controls that running profile; it is not an independent cloud-synchronized copy.
5. From a second owned profile send a plain-text message. Verify it appears on both phone and Desktop, reply from Desktop, and verify the reply on the sender. Test reconnect after briefly losing Wi-Fi, changing networks and restarting Desktop. Record observed behavior when the phone is locked or offline without assuming continuous iOS background availability.
6. Unlink from the phone and verify that Desktop loses access. Re-link only after checking a fresh verification code.

## Operate the VPS support profile

1. Open XauXat Desktop, enable **Developer tools**, then **Linked mobile / Link a mobile**. If Settings is not yet available, first link your test iPhone or finish onboarding with a disposable local test profile; that local profile is separate from the VPS profile. Select loopback address `127.0.0.1` and a fixed unused port such as `12345`. The advanced address controls appear with Developer tools enabled.
2. In the authenticated PuTTY connection to the support VPS, add a **Remote** SSH tunnel: source `127.0.0.1:12345`, destination `127.0.0.1:12345`. Keep remote connections restricted to loopback. Keep the SSH connection open; do not enable GatewayPorts or open a public firewall port.
3. Copy the new Desktop pairing link. In the VPS support CLI, enter `/crc LINK`, replacing LINK with that link. To attach to the existing console:

   ```sh
   sudo -u xauxat-support tmux -S /run/xauxat-support-chat/operator.sock attach -t support
   ```

4. Compare verification codes and enter the exact `/verify remote ctrl ...` command displayed by the CLI only after they match. Do not publish the invitation or verification code.
5. Check the profile is **XauXatSupport**, then send a synthetic support request from an owned test profile using the app's configured support contact. Receive it and reply in Desktop; confirm the reply on the test phone.
6. Close/reopen Desktop and reconnect to the same existing profile/conversation. Disconnect SSH and confirm the remote Desktop session loses transport while the VPS CLI service stays running. Reconnect the authenticated tunnel and verify recovery.
7. Detach the CLI console with **Ctrl+B, D**. Do not quit the service. Use one live support database/profile, without copying it into a second networked client. Operators take turns.

If the phone build does not yet include the native support UI from PR #166, connect manually to [the actual XauXat support contact](https://smp5.simplex.im/a#tduG95hbcB-06tBp5y9c4k8qPoNlrkNrR90wdZns-bY) for the synthetic request. This tests operator receive/reply, not the unreleased Report UI. Use **Contact XauXat** in Desktop Settings for XauXat support; an existing **Ask SimpleX Team** preset card belongs to the upstream team.

## Record actual outcomes

| Check | Status before human acceptance |
| --- | --- |
| Installer hash and correct architecture | Pending |
| Installed app opens on each target OS | Pending |
| iPhone pair, compare code, plain-text receive/reply | Pending |
| iPhone unlink revokes Desktop session | Pending |
| Restart and network-loss/reconnect | Pending |
| VPS pair through loopback-only SSH tunnel | Pending |
| Synthetic support receive and operator reply | Pending |
| SSH disconnect leaves VPS service healthy | Pending |

Record the package/source commit, OS version and pass/fail result. Automated native/GUI smoke results complement these checks; they do not mark physical-device or operator tests complete. Log errors without including real chat content, database keys, support recovery keys or pairing secrets.
