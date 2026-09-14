# XauXat Free identity boundary on iOS

XauXat Free exposes one persistent chat identity. The current identity is
created during onboarding and the SimpleX active-user state restores it on
subsequent launches.

The iOS client applies the limit in two places:

- profile switching and multi-profile management are absent from the XauXat
  interface;
- the shared iOS creation wrapper rejects a second persistent profile, covering
  onboarding re-entry and other indirect client flows.

The SimpleX multi-profile implementation remains in the fork. Temporary users
needed by the existing database migration path use an explicit internal bypass
against the temporary migration controller only.

If an existing SimpleX database already contains multiple profiles, XauXat does
not delete or merge them. The previously active profile remains the Free
identity and the others stay dormant in the local database. A future Plus
entitlement can restore their management without data loss.
