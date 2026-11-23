# Live call audio engine

Build 356 could abort immediately after connecting when the route notification
prepared the capture graph. The iPhone crash stack ends in AVFAudio's
`AUGraphParser::InitializeActiveNodesInInputChain`, then `AVAudioEngine.prepare`
inside `XauXatRealtimeAudioDevice.updateEngine`.

A native iOS probe reproduces the Objective-C exception
`false == isInputConnToConverter` with microphone → TimePitch → sink, including
pitch zero. Changing the downstream node, adding a mixer, or using a nil
connection format does not remove this input-chain restriction. A direct native
microphone → sink graph prepares and starts with and without voice processing.

Capture therefore always connects the hardware input directly to the sink in
its native format. Normal calls perform only PCM conversion for WebRTC. Legacy
voice presets use a separate real-time manual engine with a buffered source,
TimePitch and preallocated output. That engine has no hardware input chain.
Stealth retains its independent neural processor. Processing failure never
falls back to unmodified microphone audio.

Selection changes publish a new generation before rebuilding processing state.
Callbacks from an old graph are discarded; the synchronous WebRTC conversion
also clears PCM if the generation changes during delivery. Unexpected native
graph exceptions are contained with the existing Objective-C exception bridge.

Run `bash scripts/ios/test-call-audio-live.sh` on a Mac with Xcode 26.3. The harness
compiles the complete production device and LLVC source against the same pinned
WebRTC binary as the app. It verifies actual capture/playout callbacks in both
start orders, default/voiceChat modes, all five presets, ambience PCM, receiver
and speaker changes, interruptions, media reset, generation privacy and repeated
calls. Synthetic tone measurements verify all four TimePitch presets change the
frequency as intended. `probe-call-audio-graph.sh` also checks the original graph
as a negative control and the direct sink as a positive control.

These tests exercise native audio engines in the simulator. Physical acceptance
still requires calls between two iPhones, including CallKit, backgrounding,
Bluetooth and audio heard at the remote endpoint.
