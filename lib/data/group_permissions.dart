/// Who may do what in a group chat (WhatsApp-style group permissions).
///
/// Each flag is false by default = **Everyone** can do it. True =
/// **Only owner** can do it. The group creator is the owner.
///
/// Stored as three INTEGER columns on the `groups` row
/// (`perm_send`, `perm_edit`, `perm_add`) and carried on group
/// packets (`groupMsg` / `groupUpdate`) as the `permSend` /
/// `permEdit` / `permAdd` JSON keys. Default (all false) keeps
/// pre-v0.9 groups working exactly as before.
class GroupPermissions {
  /// Only the owner can send messages in the group.
  final bool sendMessagesOnlyOwner;

  /// Only the owner can change group info (name / photo). The app
  /// currently has a photo edit path (Group Info); there is no
  /// rename UI yet, so the name half of this flag gates nothing
  /// until a rename flow exists.
  final bool editInfoOnlyOwner;

  /// Only the owner can add members. The app has no add-members flow
  /// yet, so this flag currently has no entry point to gate — it
  /// exists, syncs, and is enforced at the point members could be
  /// added once such a flow exists.
  final bool addMembersOnlyOwner;

  const GroupPermissions({
    this.sendMessagesOnlyOwner = false,
    this.editInfoOnlyOwner = false,
    this.addMembersOnlyOwner = false,
  });

  GroupPermissions copyWith({
    bool? sendMessagesOnlyOwner,
    bool? editInfoOnlyOwner,
    bool? addMembersOnlyOwner,
  }) =>
      GroupPermissions(
        sendMessagesOnlyOwner:
            sendMessagesOnlyOwner ?? this.sendMessagesOnlyOwner,
        editInfoOnlyOwner: editInfoOnlyOwner ?? this.editInfoOnlyOwner,
        addMembersOnlyOwner:
            addMembersOnlyOwner ?? this.addMembersOnlyOwner,
      );

  @override
  bool operator ==(Object other) =>
      other is GroupPermissions &&
      other.sendMessagesOnlyOwner == sendMessagesOnlyOwner &&
      other.editInfoOnlyOwner == editInfoOnlyOwner &&
      other.addMembersOnlyOwner == addMembersOnlyOwner;

  @override
  int get hashCode => Object.hash(
        sendMessagesOnlyOwner,
        editInfoOnlyOwner,
        addMembersOnlyOwner,
      );
}
