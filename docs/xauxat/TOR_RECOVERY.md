# Embedded Tor readiness and recovery

The app previously reused `Ready` whenever its Tor thread was still alive. This
did not establish that the SOCKS socket or route still worked after suspension
or a network change. Relay reconnects also did not reapply a replacement dynamic
port. Separately, the HTTP route probe parsed its first TCP read as a complete
status line, which could reject a valid fragmented response.

The main app now coalesces simultaneous starts, withdraws the old readiness flag,
checks the actual route, and publishes only the verified loopback port. Existing
control sockets are checked and reopened if necessary. After bounded probe
failures, one controlled repair closes/recreates the loopback SOCKS listener and
re-enables networking in the existing Tor runtime. It does not reload a torrc,
enable a direct route, or start a second C-Tor instance. A terminated C runtime
produces a clear reopen-app error instead of attempting unsafe in-process re-entry.

The pinned framework's GETINFO/circuit helpers can consume a 650 status event
as an invalid command response. The manager now matches its own bounded control
replies and ignores asynchronous events, while still observing bootstrap/circuit
progress. Releasing a stale control socket deliberately avoids the framework's
`disconnect()` method, which sends SHUTDOWN to Tor. An interrupted repair is
also recoverable: after reauthentication, networking is re-enabled before
waiting for a circuit again.

Each attempt has a four-minute overall deadline, covering bootstrap, control
commands, probes and repair. Each probe has a 30-second deadline and each control
command a five-second deadline. Probe retries allow three checks before and three
after the single repair; the overall deadline takes precedence. Late callbacks
cannot publish readiness for an expired or superseded attempt. Outstanding probes
are cancelled when their attempt expires. Manual failures
withdraw readiness without invalidating a newer successful check.

The chat core receives the current verified configuration before app resume and
relay reconnect. Active Wi-Fi/mobile connectivity changes trigger revalidation
through the existing network observer. The diagnostics button remains usable
when the route is unhealthy, so it can retry/recover instead of being disabled.

The route probe uses only the local SOCKS endpoint and sends the destination
hostname through SOCKS. It reads a complete bounded HTTP status line, including
fragmented replies. It requests `HEAD /` from Tor Project, not the exit-IP API,
and does not log message data, contact identifiers, destinations of chats or an
exit IP. Errors distinguish the local socket, SOCKS handshake, destination reply
code, response and timeout stage. HTTP reachability is a diagnostic, not a proof
that every messaging relay is reachable or an independent anonymity audit.

## Regression checks

`bash scripts/ios/test-tor-recovery.sh` compiles the actual manager/probe on macOS.
Control-plane adapters simulate stale readiness/control sockets, one repair with
a replacement listener, persistent failure, concurrent callers, deadline races,
late callbacks, manual failure and a terminated runtime. Real loopback-only
Network.framework SOCKS peers exercise fragmented HTTP, destination refusal,
malformed replies, timeout and cancellation. They never forward to the Internet.
Adapters do not prove interoperability with the actual Tor control server: the
full iOS build and physical checks below remain required.

On two physical iPhones, record the build and exact error (without chat content)
and verify: cold bootstrap; foreground after suspension; Wi-Fi/mobile switching;
offline then online; manual retry; delayed and normal message delivery. Confirm
that all traffic still uses Tor and that relays recover with the current dynamic
port. Compare several relays if the SOCKS destination fails. A network blocking
Tor or an unavailable individual relay cannot be fixed by restarting the app;
bridges/censorship circumvention are not introduced by this change.

The reported incident included repeated app restarts without recovery. These
changes fix observable code defects, but the incident's root cause remains
unconfirmed until the physical test and exact error distinguish the failing stage.
