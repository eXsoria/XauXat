# XauXat Plus on iOS

XauXat Plus uses StoreKit 2. Build 3 temporarily includes Plus for every installation, including App Store and TestFlight Release builds, so the beta can be tested before the subscription product is configured. StoreKit remains implemented underneath and can become the authorization source again by disabling `XauXatPlusConfiguration.includedInBuild`.

## Product configuration

Create an auto-renewable monthly subscription in App Store Connect with this default product ID:

`pt.exsoria.xauxat.plus.monthly`

Set the Portuguese storefront price to EUR 2.99 per month. StoreKit supplies the localized display price shown by the app.

The app reads the product ID from the `XAUXAT_PLUS_PRODUCT_ID` Xcode build setting through `XauXatPlusProductID` in the app Info.plist. CI, another scheme, or another configuration can override that build setting without changing Swift code. A process environment value with the same name overrides it for local automated testing.

## Entitlement behavior

- Active and grace-period subscriptions authorize Plus features.
- A cancelled subscription remains active until its verified expiration date.
- Expired or revoked transactions do not authorize Plus features.
- Unverified transactions never grant access.
- Restore Purchases calls `AppStore.sync()` only after the user explicitly requests it.
- `XauXatPlusAuthorizing.isAuthorized(for:)` is the single authorization boundary for Plus features and can be replaced by a test double.
- While `XauXatPlusConfiguration.includedInBuild` is enabled, every build authorizes Plus without a purchase.

## Free-plan presentation

Implemented Plus controls remain visible to Free users. They use a subdued `Plus` and lock treatment and open the XauXat Plus purchase screen instead of silently disappearing. When the entitlement becomes inactive, XauXat immediately restores Free defaults: conversation locks and hidden-chat state are cleared, protected profiles are made visible, Decoy storage is removed, and Decoy/Duress PIN configuration is cleared.

## Local purchase testing

The Settings tab exposes **XauXat Plus**. While access is bundled, it reports **Included in this build** and hides purchase and restore controls.

To test the purchase flow itself, run a Release configuration against a StoreKit Configuration file with the same product ID, an auto-renewable monthly period, and a EUR 2.99 price. Select it in the Run scheme under Options. Do not commit Apple account credentials or signed transaction material.
