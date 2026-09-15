# Code-Locked Photos on iOS

Code-Locked Photos build on the versioned Code-Locked Content envelope and the
XauXat One-Time View transport. The SimpleX protocol and server behavior are not
changed.

## Sender flow

1. Select one or more static or animated photos.
2. Optionally enable Allow Save.
3. Select the lock action and set a code.
4. XauXat strips metadata, normalizes the image data, and seals the photo and
   caption in a code-derived authenticated envelope.
5. The transferred image preview is replaced by the same fixed 4:3 lock image
   for every protected photo. It does not disclose source pixels, colors, or
   dimensions.

The code is not stored in drafts or sent with the message. Each photo receives a
fresh random salt. A preparation failure cancels the protected send instead of
falling back to clear media.

## Recipient flow

The recipient can download the encrypted file without a Plus entitlement. The
photo is decoded only after the correct code is entered locally. After unlock,
the image and its caption remain behind Press-to-Preview and are protected in the
app switcher.

## Policy combinations

| One-Time View | Allow Save | Behavior |
| --- | --- | --- |
| On | Off | The first reveal marks the photo viewed. Releasing, backgrounding, or leaving the view deletes the local file. No export actions are shown. |
| On | On | The same one-time lifecycle applies. Save and Share are available after code unlock; using either consumes the received photo. |
| Sender copy | Either | The sender can reopen their own protected copy and export it. It is not consumed locally. |

Unlocking the envelope by itself does not consume a received photo. Consumption
starts on the first actual reveal or export action. Message lists, notifications,
quoted-message previews, message information, and context menus show only a
protected-content label and never the encrypted descriptor or original caption.

## Compatibility

Older clients see the generic unsupported-client text and the opaque lock
preview. The encrypted file remains an ordinary SimpleX attachment at the
transport layer.
