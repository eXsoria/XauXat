# XauXat Free group member limit (iOS)

XauXat Free limits private groups to 20 occupied member seats without reducing the underlying SimpleX group capacity.

## Seat accounting

- The group creator and current members occupy seats.
- Direct invitations already sent occupy seats, preventing outstanding invitations from taking the group over 20 later.
- Link requests waiting for admin review do not occupy seats until accepted.
- Removed, rejected, departed, deleted and unknown historical members do not occupy seats.

## Enforcement points

- Creating a private group enables SimpleX member review by default.
- The iOS wrapper keeps member review enabled whenever a private group profile is updated.
- Opening group-link management upgrades an older private group to reviewed admission before allowing its link or QR code to be shared.
- Contact invitations, batch invitations, link creation, link sharing and pending-member approval all perform a fresh capacity check.
- The member picker prevents selecting more contacts than the remaining capacity and explains the limit before submission.

Existing imported groups with more than 20 members keep every member. XauXat blocks only new admissions while they remain at or above the Free limit. Channel/relay behavior and the larger group support in the SimpleX core are unchanged, so a future Plus entitlement can replace this iOS policy without a protocol fork.
