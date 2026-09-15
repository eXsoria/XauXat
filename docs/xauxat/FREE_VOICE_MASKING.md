# Free voice masking on iOS

XauXat Free includes one local voice transformation named **Veil** for newly
recorded voice messages.

## Privacy behaviour

- The transformation runs entirely on the iOS device using AVFoundation.
- No recording or audio sample is sent to an external service for processing.
- The transformed AAC file atomically replaces the original recording.
- No backup copy of the unmasked recording is kept by XauXat.
- The existing voice preview plays the transformed file before it is sent.

## User flow

After finishing a recording, the composer offers **Mask voice**. While the file
is being transformed, sending and cancellation are disabled. When complete, the
composer shows **Voice masked · Veil** and the user can preview or send it.

The preset chooser also shows the additional XauXat Plus transformations. Free
users can see that they exist, but Veil remains the only selectable preset until
Plus is active.

Voice masking is deliberately unavailable while editing an already-sent voice
message. To undo the transformation before sending, discard the draft and record
a new message.
