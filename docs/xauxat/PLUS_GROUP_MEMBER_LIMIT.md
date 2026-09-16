# XauXat Plus group member limit (iOS)

XauXat Plus raises the private-group admission limit from 20 to 100 occupied seats. The limit is an iOS product policy layered over the existing SimpleX group protocol.

## Why the initial limit is 100

- The SimpleX core does not impose the XauXat Free limit of 20 on private groups.
- The signed relay-group roster parser and promotion guard have a hard bound of 256 privileged roster entries (`maxGroupRosterSize` in `src/Simplex/Chat/Protocol.hs`). A 100-member product limit remains well below that protocol safety bound.
- The core relation-index tests include a 10,000-member data-structure case (`tests/MemberRelationsTests.hs`). This verifies that local relation indexing is not constrained to small groups, but it is not presented as a 10,000-device messaging test.
- Delivery receipts remain disabled by the existing SimpleX UI once a group exceeds 20 current members. Raising XauXat admission capacity does not claim or enable large-group receipts.

The 100-member cap is intentionally conservative. Raising it above 100 requires a separate multi-device load test covering invitations, approvals, fan-out, reconnects, memory and database growth on currently supported iPhones.

## Enforcement and downgrade

- Direct invitations, batch invitations, link creation and sharing, short-link creation, and pending-member approval re-read the current occupied-seat count before acting.
- Private group links continue to use reviewed admission, including for Plus groups, so a shared link never bypasses administrator approval.
- When Plus expires, no member or group is deleted. Existing groups remain usable, visible and connected; new admissions are blocked while the group is at or above the Free 20-member limit.
- The UI reports the active plan limit and occupied-seat count instead of implying that Plus groups are unlimited.
