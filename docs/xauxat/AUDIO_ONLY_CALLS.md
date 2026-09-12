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

This restriction applies to call video. Sending and receiving video messages is
unchanged.

## Release verification

Before promotion, test an audio call in both directions between XauXat and a
current SimpleX client. Also send a video-call invitation from SimpleX to
XauXat and confirm that XauXat answers with audio only, never requests camera
permission and never renders remote video.
