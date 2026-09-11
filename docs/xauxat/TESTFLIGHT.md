# XauXat TestFlight delivery

TestFlight is the intended iPhone beta channel. The pull-request workflow only
produces an unsigned Simulator app, which cannot be installed on a physical
iPhone.

## Apple setup required

Create identifiers owned by Exsoria. Final names can change, but they must not
reuse SimpleX Chat identifiers or credentials.

- app: `dev.exsoria.xauxat`
- notification service extension: `dev.exsoria.xauxat.NSE`
- share extension: `dev.exsoria.xauxat.SE`
- app group: `group.dev.exsoria.xauxat`

Then create:

1. an App Store Connect app record;
2. distribution certificates and provisioning profiles for all targets;
3. an App Store Connect API key limited to the access required for uploads;
4. XauXat APNs credentials when instant notifications enter scope.

## GitHub secrets

The release workflow will require these encrypted values:

- `APPLE_TEAM_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY`
- signing certificate and password
- provisioning profiles for the app and enabled extensions

No signed release workflow is enabled until the Apple identifiers exist and a
local signed archive has passed. This keeps the first CI milestone honest: it
proves compilation, not distribution credentials that are not configured yet.

## Release gate

A TestFlight upload must come from an explicit release revision after:

- native libraries and Tor dependency hashes are recorded;
- proprietary upstream graphics have been replaced;
- bundle IDs, app groups and entitlements belong to XauXat;
- calls and unverified network paths are disabled for the Tor beta;
- the Tor acceptance checks in `TOR_FOUNDATION.md` pass;
- the complete corresponding source revision is public.
