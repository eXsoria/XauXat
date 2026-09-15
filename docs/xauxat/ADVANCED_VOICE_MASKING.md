# Advanced voice masking on iOS

XauXat Plus adds Alloy, Hollow, and Wisp to the free Veil voice transformation.
All four presets use the same local AVFoundation offline-rendering pipeline. No
recording, preview, or audio sample leaves the device.

## Composer flow

- Finishing a new voice recording exposes the voice-mask chooser.
- Veil remains visible and available on Free. The Plus presets remain visible
  with a lock when Plus is inactive and open the existing XauXat Plus screen.
- Each available preset has a direct preview action. Previews are always
  rendered from the untouched draft, so the user can compare any Plus preset
  directly with Veil before applying one.
- Preview files use complete file protection, are excluded from system backup,
  are loaded into memory for playback, and are deleted immediately after the
  render completes or fails.
- Applying a preset atomically replaces the original draft. No unmasked backup
  is retained by XauXat.

The user can explicitly enable **Use this preset next time** before applying.
Only then is the preset identifier saved locally. Without that switch, the next
recording uses Veil as the initial selection. If Plus is no longer active, the
saved advanced preset is ignored and the composer returns to Veil.

## Audio properties

The presets vary pitch while keeping the playback rate at `1.0`. Rendering uses
the source sample rate, channel count, and exact source-frame duration, then
writes AAC with the same voice-message bitrate used by the recorder. This keeps
message duration stable and avoids an unnecessary network or cloud conversion.
