# Group invite permissions

XauXat Free lets a group admin choose who may invite new members:

- admins only (the default, including groups created by older clients);
- admins and moderators;
- all members.

The policy is stored in the existing encrypted group profile and is sent to the
group with the normal encrypted group-profile update. It applies to direct
invites, group invite links and their QR codes. The inviter must also have a
role at least as high as the role assigned to the new member.

Only active admins and owners can change the policy. Clients validate the
inviter against the policy when receiving an invitation, so bypassing the iOS
controls does not bypass the rule. Existing links owned by a member who loses
permission stop accepting join requests. Link revocation remains unchanged.

The iOS pipeline builds the native SimpleX library from the XauXat fork source
before building the app. This is required because the policy is enforced in the
Haskell protocol core, not only in SwiftUI.
