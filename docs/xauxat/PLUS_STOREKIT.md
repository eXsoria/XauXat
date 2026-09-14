# XauXat Plus on iOS

XauXat Plus uses StoreKit 2 and grants access only from App Store verified transactions. There is no local premium toggle.

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

## Local purchase testing

Create a StoreKit Configuration file in Xcode with the same product ID, an auto-renewable monthly period, and a EUR 2.99 price. Select it in the Run scheme under Options. Do not commit Apple account credentials or signed transaction material.
