# XauXat

XauXat is an independent, work-in-progress mobile client for the SimpleX
network, maintained by Exsoria. It is a public native fork of SimpleX Chat and
is not affiliated with or endorsed by SimpleX Chat.

The first engineering milestone is embedded Tor on iOS and Android with no
direct-network fallback. The broader product roadmap is intentionally out of
scope until that transport boundary is implemented and verified.

## Current status

- Upstream baseline: SimpleX Chat 7.0.2
- Integration branch: `xauxat/main`
- Active milestone: embedded Tor foundation
- iOS baseline: locally compiled for x86_64 Simulator
- Android Tor integration: not implemented yet
- TestFlight: not configured yet

The current app source still contains upstream product names, bundle IDs and
graphics. It is not ready for distribution. These must be replaced with
XauXat-owned identifiers and assets before any beta.

## Architecture and delivery

- [Embedded Tor foundation](docs/xauxat/TOR_FOUNDATION.md)
- [TestFlight delivery requirements](docs/xauxat/TESTFLIGHT.md)
- [SimpleX protocol and platform documentation](docs/SIMPLEX.md)

The pull-request pipeline prepares checksum-pinned native libraries and builds
an unsigned iOS Simulator app. Signed device distribution will use TestFlight
after Exsoria Apple identifiers and signing credentials are configured.

## Upstream

XauXat tracks the public
[`simplex-chat/simplex-chat`](https://github.com/simplex-chat/simplex-chat)
repository. Preserve the `upstream` remote locally when updating the fork:

```sh
git remote add upstream https://github.com/simplex-chat/simplex-chat.git
git fetch upstream
```

Protocol compatibility, public-infrastructure conditions and upstream changes
must be reviewed before each XauXat release.

## Licence and attribution

The code in this repository is distributed under GNU AGPLv3. See
[LICENSE](LICENSE). Original copyright notices are retained in the source and
history.

SimpleX and SimpleX Chat are trademarks of their respective owner. XauXat does
not use the SimpleX name or graphics as its own brand. Upstream graphic assets
remain subject to their separate
[asset licence](assets/ASSETS_LICENSE.md) and must not ship in a modified
XauXat distribution.
