# Composable advanced group access rules on iOS

The XauXat Plus group access editor applies access count, individual-access mode, code protection, and expiry as one validated policy. Before creation it shows a plain-language summary and rejects past expiry dates, invalid counts, or any request larger than the group's remaining capacity.

The shared summary states the group, use count or individual access ID, whether a code is required, and the expiry. It never contains the access code. The protected link and code remain separate share operations.

All selected conditions are enforced together. A code-protected access must first unlock locally, its authenticated envelope must still be before the deadline, and one of its independent SimpleX one-time slots must still be available. Revocation deletes the corresponding underlying slots and remains terminal.

The policy evaluator has automated coverage for deterministic condition order, concurrent claims at the maximum-use boundary, exact expiry behavior, terminal revocation, combined editor validation, and code-free summaries. The runtime limit remains backed by separate SimpleX one-time invitations, which provide the cross-device atomic claim boundary.
