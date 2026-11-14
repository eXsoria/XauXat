# Real-time voice masking on iOS

XauXat Plus can transform microphone audio during private audio calls. The
implementation supplies WebRTC with a custom `RTCAudioDevice`: microphone PCM
passes through an `AVAudioUnitTimePitch` node and is converted to WebRTC's
16-bit input format only after the selected transformation has been applied.
The original microphone frames are never handed to WebRTC while masking is on.

## Call flow

- The call screen keeps the control visible for Free users, with a lock that
  opens the existing XauXat Plus screen.
- Plus users can enable masking and switch between Veil, Alloy, Hollow, and
  Wisp without renegotiating or reconnecting the call.
- A preset change updates the existing processing node. An 80 ms outgoing
  silence guard prevents unprocessed transition frames from being delivered.
- Processing is in memory and local to the device. No temporary recording,
  server request, or cloud conversion is used.
- If the processing graph cannot run on the current audio route, XauXat fails
  closed: no microphone frames are delivered while masking remains requested.
  The user can change route or explicitly disable masking to restore the normal
  microphone path.
- If Plus access ends during a call, masking is disabled and the call returns
  to the default microphone behaviour.

## Validation boundary

The iOS Simulator build and launch validate integration and lifecycle safety,
but cannot establish real-device acoustic latency or every Bluetooth and
CallKit route. Before release, test an audio call between two current iPhones,
change all presets while speaking, and repeat on receiver, speaker, wired, and
Bluetooth routes. Confirm that the call remains connected and that no original
voice is heard during either preset transitions or forced processing failures.

## Stealth in calls and voice notes

In a private audio call, open the XauXat mask button and enable **Stealth**.
Choose **use voice mask** to start with Stealth, or **Answer with voice mask**
in the in-app incoming call banner. The system CallKit screen has only the
standard iOS answer controls. Voice notes offer Stealth in the preset picker.
Start with the built-in microphone. Have the recipient compare normal and
converted speech during a conversation, including quick turns and overlapping
speech. Switching the toggle off restores the normal microphone.

The bundled Core ML model uses the MIT-licensed KoeAI LLVC `G_500000` checkpoint,
with a single target voice. Inference stays on the phone. Live capture accepts
16 kHz and 48 kHz capture routes and sends silence during startup or failure.
Stealth is available independently of Plus and has no validated speaker
anonymization claim.

To reproduce the model, run [export-llvc.py](../../scripts/ios/export-llvc.py)
with PyTorch, SpeechBrain and Core ML Tools on macOS. Pass the
[upstream source at 1627c5d](https://github.com/KoeAI/LLVC/tree/1627c5d358cf9bb2b92b0ccc513d8b36807c923d),
the [G_500000.pth checkpoint](https://huggingface.co/KoeAI/llvc_models/tree/main/models/checkpoints/llvc)
and the output path for `XauXatLLVC.mlpackage`. The script verifies the
checkpoint hash and compares successive Core ML outputs with upstream PyTorch.

## Third-party reference

The AVAudioEngine bridge is adapted from Yury Yaroshevich's MIT-licensed
`RTCAudioDevice` example, which is referenced by WebRTC's own Objective-C audio
device header. The required license notice is in
`docs/xauxat/THIRD_PARTY_NOTICES.md`.
