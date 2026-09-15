# XauXat iOS notification token lifecycle

This document covers the app-side lifecycle tracked by issue #77. It does not
claim that XauXat APNs credentials, the notification server, or Tor inside the
Notification Service Extension are complete.

## Persistent intent

XauXat stores the notification mode selected by the user independently from the
token currently stored by the SimpleX core. This prevents a late APNs callback
from losing the onboarding default or a user selection.

- New XauXat profiles persist `INSTANT` during onboarding, even when iOS has not
  delivered a device token yet.
- Existing profiles migrate their current SimpleX notification mode once.
- Selecting `OFF` is authoritative. It remains off across relaunches and a late
  device-token callback cannot turn notifications back on.

## Reconciliation events

Registration is reconciled when:

1. the SimpleX chat core finishes starting;
2. iOS supplies or changes the APNs device token;
3. the user changes the notification mode;
4. the notification settings screen is opened.

The APNs provider environment is part of the token identity, so moving between
development and production also triggers registration.

Only one registration operation runs at a time. A failed operation can be
retried twice with bounded delays. A new app launch performs reconciliation
again, allowing invalid, expired, or changed tokens to recover without requiring
the user to toggle the setting.

## UI states

The XauXat notification screen distinguishes:

- notifications off;
- waiting for iOS to supply an APNs token;
- registration in progress;
- the token status returned by the SimpleX core;
- an actionable registration error.

The selected mode represents user intent. Token status represents the actual
registration state.

## Manual device checks

The production APNs epic must exercise these orderings on a physical iPhone:

- token before chat startup;
- token after chat startup;
- onboarding completion before token delivery;
- Instant to Off while registered;
- Off followed by a fresh APNs callback;
- token replacement and APNs environment change;
- transient network error followed by automatic retry;
- expired or invalid token followed by app relaunch.

Simulator launch validation is useful for crashes and UI regressions, but it is
not proof of the real APNs lifecycle.
