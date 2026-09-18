# Notification extension Tor boundary and verification

This document defines what XauXat protects after an iOS push and how to prove
the route on a physical iPhone. Simulator builds are a development check, not
acceptance evidence for APNs, extension scheduling or packet routing.

## Privacy boundary

```text
XauXat NTF server -> Apple APNs -> iPhone
                                      |
                                      v
                           Notification Service Extension
                                      |
                              127.0.0.1 dynamic SOCKS
                                      |
                              extension-owned Tor
                                      |
                         SimpleX SMP and XFTP relays
```

The NTF server to APNs and APNs to device legs use Apple infrastructure and do
not travel through Tor. The APNs payload contains the encrypted SimpleX
notification envelope. Tor protection starts when the extension wakes and
retrieves SimpleX data from SMP or XFTP.

The main app and the extension are separate processes. The extension never
uses the main app's dynamic SOCKS port. It owns a Tor thread, a private
`TorNSE` data directory and loopback-only dynamic control and SOCKS listeners.

## Runtime contract

Before every retrieval, including after suspension or a network change, the
extension resets the SimpleX network configuration to the closed endpoint
`127.0.0.1:1`. It then asks its Tor controller for the current circuit state
and SOCKS listener. Only an established circuit and a valid loopback listener
allow the SimpleX core to start or resume.

The resulting SimpleX configuration always uses SOCKS, prefers onion relay
addresses and never falls back to a direct SMP or XFTP connection. Tor has an
18-second bootstrap budget so notification processing retains part of iOS's
approximately 30-second extension window. A timeout, stopped Tor thread,
authentication failure or invalid listener delivers only the opaque best
attempt notification. It does not start the core.

Logs may contain lifecycle states, counts and Tor bootstrap percentage. They
must not contain message bodies, contact names, invite secrets, relay
credentials or stable user, contact, entity or message identifiers.

## Repository checks

Run from the repository root:

```sh
./scripts/ios/verify-nse-tor-policy.sh
```

The check guards the pinned Tor dependency, loopback-only listener, per-request
circuit health check, closed startup ordering and mandatory SOCKS policy. It is
a regression check, not network evidence.

## Physical-device packet proof

Use a current physical iPhone with a Debug or internal Release build signed for
the XauXat App ID. Record the iPhone model, iOS version, XauXat commit, network
type, notification mode and test time.

1. On the Mac, create a remote virtual interface for the connected iPhone:

   ```sh
   rvictl -s <iphone-udid>
   sudo tcpdump -i rvi0 -n -w xauxat-nse.pcap
   ```

2. Record the public IP addresses of every configured SimpleX SMP, XFTP and NTF
   hostname before the test. Keep Tor guard traffic separate from relay and NTF
   destination traffic in the analysis.
3. Put XauXat in each required lifecycle state, send a message from a second
   device and wait for the notification to be rendered.
4. Stop the capture and inspect it with Wireshark or `tshark`. Connections from
   the iPhone to Apple push infrastructure and Tor guard nodes are expected.
   There must be no direct connection from the extension to any recorded SMP or
   XFTP relay address.
5. Repeat while Tor cannot establish a circuit. The encrypted best-attempt push
   may still arrive through APNs, but no SMP or XFTP connection may leave the
   device and no decrypted sender or message content may be shown.
6. Repeat across Wi-Fi, mobile data, offline recovery and a Wi-Fi/mobile-data
   handoff. A route reused after a handoff must be health-checked again before
   the SimpleX core runs.

Keep the `.pcap`, unified-log export and screen recording as private test
artifacts. They can contain network metadata and must not be attached to a
public issue without redaction.

## Acceptance record

Issue #80 can close only after the full lifecycle and network-change cases pass
on current iPhone hardware and the capture shows zero direct SMP/XFTP relay
connections. The broader two-device notification matrix is tracked separately
by issue #79.
