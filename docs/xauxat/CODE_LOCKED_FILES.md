# Code-Locked files on iOS

XauXat Plus can protect a file or document with the same local code-lock
envelope used for text, photos, audio, and video. No SimpleX server or protocol
change is required.

## Send path

1. The selected file remains outside the message until protection succeeds.
2. XauXat reads it under its document-picker security scope.
3. The original name, MIME type, optional caption, and file bytes are sealed in
   the authenticated code-lock envelope.
4. Only a generated `.xauxat` file name and the generic protected-file marker
   are handed to the existing SimpleX send path.
5. If any preparation step fails, no message or plaintext fallback is sent.

## Receive and preview path

- The chat row, chat-list preview, notifications, forwarding, and context menus
  expose only a generic protected-file label while locked.
- The transferred envelope is decrypted from local storage only to validate its
  type. The user code is checked locally and is never sent or persisted.
- The original file name and size become visible only after a correct code.
- Opening the file uses a read-only in-app Quick Look controller without share
  or editing controls. The standard file Share Sheet is never given its URL.
- The clear preview file has a random name, preserves only the required
  extension, uses iOS complete file protection, and has `0600` permissions.
- The clear copy is removed when preview closes, the app becomes inactive,
  screen capture begins, a screenshot is detected, the chat view disappears,
  or the next app launch sweeps interrupted previews.

This first version follows the existing SimpleX file-size limits. Attempt limits
and failed-attempt destruction are implemented separately by their roadmap
issues.
