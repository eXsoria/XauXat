# Verifying XauXat's Tor route on iOS

This procedure verifies the XauXat-managed route used by the SimpleX protocol
(SMP and XFTP). It does not claim that unrelated Apple traffic, notification
delivery, WebRTC calls, or links opened outside the app use Tor.

## 1. In-app verification

Open `Settings > Private connection` after XauXat finishes starting.

The three expected results are:

- `Embedded Tor: Ready`: Tor has authenticated locally and established a circuit.
- `SimpleX route: Forced through Tor`: the current `NetCfg` uses the dynamic
  `127.0.0.1` SOCKS endpoint in `always` mode and prefers onion endpoints.
- `Tor route probe: Passed`: a fresh SOCKS5 tunnel through that exact endpoint
  reached `check.torproject.org`. The probe sends no chat data and neither
  requests nor stores an exit IP.

If the managed route is not ready, XauXat refuses to configure or start the
SimpleX controller. The placeholder proxy is deliberately closed, so failure
does not fall back to a direct connection.

## 2. Device packet capture

Use a current physical iPhone and the current Xcode toolchain. Apple's Remote
Virtual Interface captures the full networking stack of the attached device,
so close other apps and make a note of the exact test interval.

1. Connect the unlocked iPhone to the Mac over USB and trust the Mac.
2. Get the iPhone UDID from Xcode's Devices and Simulators window.
3. Create the remote interface:

   ```sh
   rvictl -s <IPHONE_UDID>
   ```

4. Record the interface name printed by `rvictl` (normally `rvi0`) and start a
   capture:

   ```sh
   sudo tcpdump -i rvi0 -nn -w xauxat-tor.pcap
   ```

5. Launch XauXat, wait for all three in-app checks, then send and receive text,
   an image, and a file. Stop the capture immediately afterwards.
6. Open `xauxat-tor.pcap` in Wireshark. During the marked interval, application
   relay traffic must go only to Tor relay addresses. There must be no direct
   TCP connection from XauXat to the resolved public addresses of its SMP or
   XFTP servers.
7. Remove the remote interface when finished:

   ```sh
   rvictl -x <IPHONE_UDID>
   ```

Apple documents RVI setup and `tcpdump` capture in
[Recording a Packet Trace](https://developer.apple.com/documentation/network/recording-a-packet-trace).

## 3. Release gate

A candidate build passes the Tor gate only when all of the following are true
on a physical iPhone:

- the embedded Tor framework and app executable are `arm64`;
- the in-app status is `Ready / Forced through Tor / Passed`;
- text and file transfers work;
- the capture has no direct SMP/XFTP relay connection;
- preventing Tor bootstrap makes the app fail closed instead of connecting
  directly.

Archive the `.pcap`, app commit SHA, device model, iOS version, and UTC test
window with the release evidence. Packet captures can contain sensitive
metadata, so do not commit them to Git.
