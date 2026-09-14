# Press-to-Preview on iOS

`XauXatPressToPreview` is the shared SwiftUI protection primitive for content
that must remain visible only during deliberate interaction. Its content is a
generic SwiftUI view, so the same lifecycle applies to text, photos, audio,
video, and file/document presentations added by the code-locked content work.

## Interaction

- Touching and holding reveals the protected view immediately.
- Releasing, moving outside the gesture tolerance, cancelling the gesture, or
  leaving the view hides it immediately.
- VoiceOver exposes a named action that reveals for ten seconds, announces the
  state, and then hides automatically. A second action can hide it sooner.
- Content remains visible by default only when it is deliberately revealed;
  the placeholder never depends on an entrance animation.

## Screen protection

- The existing XauXat root and sheet protection covers the App Switcher.
- Moving the scene away from active state hides the preview.
- Active screen recording or mirroring prevents reveal and hides an already
  visible preview when capture starts.
- iOS does not provide a supported API to prevent a hardware screenshot before
  it is captured. When iOS posts its screenshot notification, the preview hides
  immediately and the current one-time photo is consumed.

## Current integration

With an active Plus entitlement, received One-Time View photos use
Press-to-Preview instead of opening a persistent full-screen view. The first
reveal marks the photo consumed and releasing the interaction removes the local
file. Free behaviour remains the existing tap-once flow.
