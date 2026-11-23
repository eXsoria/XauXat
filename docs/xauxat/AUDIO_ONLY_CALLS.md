# XauXat iOS audio-only calls

XauXat for iOS currently exposes private audio calls only. The upstream SimpleX WebRTC
implementation remains in the fork so future upstream rebases and an explicitly
planned product change do not require reconstructing the calling stack.

The product boundary is enforced in addition to the visible interface:

- chat toolbars and contact or group-member details offer only audio calls;
- Siri and CallKit requests are normalized to audio;
- CallKit declares that the app does not support video;
- incoming invitations and their notifications are presented and answered as
  audio calls;
- camera and video controls are not rendered during an active call;
- remote camera state cannot switch the XauXat call interface to video.

Android is intentionally outside this milestone.

## Feedback while establishing a call

After answering, the in-app call screen distinguishes preparing audio, waiting
for the other device's automatic signaling response and connecting audio. An
indeterminate activity indicator and elapsed seconds remain visible until the
connection succeeds or the call ends. After ten seconds, a gentle message offers
the choice to keep waiting or end the call. The timer starts at acceptance on the
incoming side, or receipt of the offer on the outgoing side; ordinary ringing
time is excluded. Collapsing and reopening the screen does not reset it.

The former “waiting for confirmation” label meant waiting for the other device's
WebRTC answer, not a further action by either person. A reported fifteen-second
wait is not yet attributed to one cause. The existing initial ICE collection is
bounded to 750 ms per endpoint; signaling through messaging relays, the other
device's preparation and network recovery must be measured separately before
changing connection behavior. These feedback changes do not claim a latency
reduction or alter call negotiation, Tor routing, relay policy or audio capture.

“Private connection → Copy connection diagnostics” includes the latest call's
coarse state transitions and elapsed seconds. Only one bounded timeline stays in
process memory. It contains no contact, call UUID, SDP, candidate, address, key or
raw error, and is never uploaded automatically. Copy diagnostics on both phones
after a slow call to distinguish local preparation, offer/answer waiting and
audio connection. The native iOS lock-screen call interface is managed by iOS;
this additional feedback appears in XauXat's call screen.

This restriction applies to call video. Sending and receiving video messages is
unchanged.

## Release verification

Before promotion, test an audio call in both directions between XauXat and a
current SimpleX client. Also send a video-call invitation from SimpleX to
XauXat and confirm that XauXat answers with audio only, never requests camera
permission and never renders remote video.
