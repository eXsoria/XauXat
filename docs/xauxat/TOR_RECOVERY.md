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

## Coordinated and selective recovery

`XauXatConnectionRecoveryManager` now serializes the complete operation: select
targets, verify Tor, apply the current configuration, then reconnect the core.
Concurrent requests share work only when the operation covers their scope,
profile and network generation. A global request arriving during a selected-relay
repair waits for it instead of running alongside it. Manual retries always ask
for a fresh route check; automatic/foreground follow-up may reuse a verification
for at most 15 seconds. This lease also requires a live runtime and the managed
configuration. Path changes and suspension invalidate it, including checks still
in progress. The ordinary `ensureReady()` default remains a fresh check.

Pending delivery/subscription recovery keeps the 8/20/45/90-second backoff but
selects only current-profile relays with pending subscriptions or connecting/error
sessions and no connected session. Pending subscriptions are eligible even if
other subscriptions to the same relay are active: the native reconnect command
operates at relay granularity, not individual queues. A healthy/empty snapshot
does not probe, reconnect or rotate Tor. Summary failure is surfaced without a
global fallback. Each selected relay has a 15-second cooldown; a command failure
does not prevent attempts for the other selected relays. There is no periodic
NEWNYM based on elapsed retries. Core acknowledgements, queue management and
ordinary reconnects remain owned by the native core. A still-connecting session
or pending subscription first gets an observed grace window equal to the native
background connect plus command timeouts (currently 100 seconds with the forced
proxy defaults). Explicit disconnected session errors are eligible at the next
backoff check. A successful/empty snapshot clears stale stall timers; reconnects
start a new grace window, so recovery cannot repeatedly interrupt an ordinary
Tor connection attempt before its timeout.

Global recovery is retained for explicit global retry, foreground resume, a
settled network-path change, or a verified replacement SOCKS endpoint. It is
needed when old sessions reference a replaced port. The route probe and its
bounded control-plane repair remain as documented above; this change does not
remove the diagnostic dependency on Tor Project or prove every relay reachable.
The pinned simplexmq `setNetworkConfig` already reconnects all sessions when the
configuration changes. The adapter compares the actual core configuration and
reports that reconnect to the coordinator; neither recovery nor foreground adds
a second reconnect command immediately after applying it.

Every NWPathMonitor callback invalidates freshness, even if its coarse network
type remains Wi-Fi. Availability changes are forwarded to the core immediately;
global recovery waits for one second of path stability. Old monitor callbacks
are discarded. Profile/offline/epoch/cancellation checks are repeated after
awaits and before issuing relay commands. Entering background pauses the app's
automatic recovery; it resumes with pending work when the app becomes active.
This does not grant extra background execution or change the NSE's separate Tor.

The outbound tracker finishes at `sndSent` as well as a receipt/error status.
Thus missing delivery receipts (`Sent to relay` versus `Delivered`) do not by
themselves trigger recovery. Publishing tracker changes re-reads current state
under its lock rather than sending stale booleans to the main actor.

Private connection settings offer **Copy connection diagnostics**. The bounded
80-event in-memory journal contains app version/build, elapsed seconds, allowlisted
stages/reasons and aggregate relay counts. It includes no message/contact data,
server addresses, profile IDs, keys, IPs or raw errors, and uploads nothing.
It resets when the app process exits. An accepted reconnect command is logged as
such; it is not evidence of successful message delivery.

The macOS script also compiles the actual coordinator with injected core/route
boundaries. Checks cover shared operations, scope widening, selective targets,
cooldowns, path flaps, late results, profile changes, suspension, offline backoff,
configuration/route failures and diagnostic redaction. Physical validation must
add a healthy relay alongside a failing relay and verify that recovery does not
interrupt the healthy conversation, while messages and receipts recover in both
directions after Wi-Fi/mobile/offline/foreground transitions.
