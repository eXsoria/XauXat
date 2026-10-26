# Local stickers and soundboard (iOS)

The composer has a keyboard-sized tray with sticker and soundboard tabs. Its
pack shortcuts show all items, recents, favorites, built-in XauXat items and
imports. Search matches local titles only. Long-press an item to favorite or
remove it. The built-in emoji stickers and three synthesized sounds are created
on-device; no catalog, search endpoint, analytics or remote media URL is used.

A sticker tap sends an ordinary SimpleX image attachment immediately and keeps
the tray and unsent text. Sounds have independent preview and selection buttons;
selection stages a fresh voice-message draft, and the composer Send button
performs the actual send. Recipients use the existing tap-to-play voice UI.
Soundboard preview is disabled during calls. There is no microphone recording or
permission request in the library. This version does not mix sounds into calls.

Imports accept local PNG/JPEG/WebP or M4A/MP3/WAV/AIFF/CAF files, up to 10 MiB
each. Images are downsampled to a maximum 512-pixel edge and rebuilt as PNGs,
preserving transparency and dropping source metadata. Sounds are decoded to
bounded PCM and encoded into a fresh AAC/M4A file; the maximum duration is 15
seconds. There are at most 100 entries per profile, including built-in media.
Multiple selected files are committed individually; earlier imports remain if a
later file fails. Animated images are imported as a static frame.

Library media, titles, favorites and recents are AES-GCM encrypted with a random
device-only key in the existing Keychain access group. Each profile in each
primary/decoy storage scope has a separate key and directory under app_files.
Files use complete iOS file protection and are excluded from system backups.
Profile deletion removes the directory and key; whole-database file deletion
also removes the library directories. Device migration does not transfer the
device-only keys, so users must import their packs again on another device.

Outgoing attachments use the existing native SimpleX send APIs and configured
Tor route; no transport or cryptographic protocol is added. Standard image and
voice rendering preserves compatibility with existing clients. In this first
version a received sticker is rendered as an image, and packs are local: there
is no WhatsApp pack/ZIP import, pack sharing or received-sticker management.

The simulator harness compiles the production library and tray. It exercises
real media encoding/metadata removal, encrypted persistence, wrong keys,
tampering, swapped ciphertext, profile isolation, deletion, local file limits,
remote-URL rejection, favorites/recents, permissions and separate sound preview.
Its surrounding chat/composer are fixtures. Full application CI also compiles
the integration for device and simulator. Real-device audio, Files-provider
imports and two-device encrypted delivery still need acceptance testing.
