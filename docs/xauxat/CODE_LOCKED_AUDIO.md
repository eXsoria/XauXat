# Code-Locked Audio on iOS

Code-Locked Audio uses the shared authenticated Code-Locked Content envelope.
It does not change the SimpleX protocol or server behavior.

## Sender flow

After recording an audio message, a Plus user can set a content code. XauXat
reads the final recording bytes, including any local voice transformation that
has already been applied, and seals these values inside the envelope:

- audio bytes;
- caption;
- real duration;
- generic filename and MIME type.

The public SimpleX voice message carries a duration of zero and a protected-audio
marker. If protection fails, XauXat sends nothing and keeps the original
recording available for retry. After successful protection, the unprotected
recording file is removed.

## Recipient flow

The encrypted attachment can be downloaded without a Plus entitlement. Before
the correct code is entered, the chat and conversation list show no player,
slider, waveform, caption, or real duration. Notifications and quoted-message
previews use only the `Protected audio` label.

After local unlock, XauXat creates the audio player directly from decrypted bytes
in memory. It does not write a clear playback copy to disk and it does not export
the file. Playback stops and the unlocked payload is released when the app moves
to the background or the view disappears.

## Voice Masking compatibility

Code locking is applied to the final recording file selected by the composer.
It does not decode, re-encode, or bypass local Voice Masking, so a masked
recording remains masked after protection and unlock.
