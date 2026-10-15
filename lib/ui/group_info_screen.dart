import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../ble/ble_protocol.dart';
import '../ble/ble_transport.dart';
import '../core/constants.dart';
import '../core/identity.dart';
import '../data/chat_repository.dart';
import '../data/group_permissions.dart';
import '../data/models.dart';

/// Group Info: photo, name, owner, member list, and the Group
/// Permissions section (send messages / edit info / add members —
/// Everyone / Only owner). Only the owner can change permissions;
/// everyone else sees them read-only. The photo edit is gated by the
/// edit-info permission.
///
/// The group photo is local-only, like the profile photo: it is
/// copied into app storage and its path stored on the group row. It
/// is never sent to peers, so other phones keep the default avatar.
class GroupInfoScreen extends StatelessWidget {
  final Group group;

  const GroupInfoScreen({super.key, required this.group});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<ChatRepository>();
    final identity = context.watch<IdentityStore>();
    final fresh = repo.groupById(group.id) ?? group;
    final isOwner = fresh.ownerId == identity.userId;
    final memberCount = fresh.members.length + 1;
    final ownerName = _ownerName(fresh, identity.userId);
    // Edit-info permission: Everyone (or no known owner) → anyone
    // may change the photo; Only owner → only the owner may.
    final canEditInfo = !fresh.permissions.editInfoOnlyOwner ||
        fresh.ownerId == null ||
        isOwner;

    return Scaffold(
      backgroundColor: CcColors.abyss,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Text(
          'Group info',
          style: GoogleFonts.nunito(
            fontWeight: FontWeight.w700,
            color: CcColors.textPrimary,
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            Center(
              child: _groupPhoto(context, fresh, canEditInfo),
            ),
            const SizedBox(height: 14),
            Center(
              child: Text(
                fresh.name,
                textAlign: TextAlign.center,
                style: GoogleFonts.nunito(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: CcColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                'Group · $memberCount members',
                style: GoogleFonts.dmSans(
                  fontSize: 13,
                  color: CcColors.textMuted,
                ),
              ),
            ),
            const SizedBox(height: 24),
            _row(
              icon: Icons.person_rounded,
              title: 'Created by',
              subtitle: ownerName,
            ),
            const SizedBox(height: 24),
            _permissionsSection(context, fresh, identity, isOwner),
            const SizedBox(height: 24),
            Text(
              '$memberCount members',
              style: GoogleFonts.nunito(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: CcColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            _memberRow(
              name: 'You',
              badge: isOwner ? 'Owner' : null,
              self: true,
            ),
            ...fresh.members.entries.map((e) => _memberRow(
                  name: e.value,
                  badge:
                      e.key == fresh.ownerId ? 'Owner' : null,
                )),
          ],
        ),
      ),
    );
  }

  String _ownerName(Group group, String myUserId) {
    final ownerId = group.ownerId;
    if (ownerId == null) return 'Unknown (created before v0.9)';
    if (ownerId == myUserId) return 'You';
    return group.members[ownerId] ?? 'A former member';
  }

  Widget _row({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: CcGlass.panel(radius: 18),
      child: Row(
        children: [
          Icon(icon, color: CcColors.aquaCyan, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.nunito(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: CcColors.textPrimary,
                  ),
                ),
                Text(
                  subtitle,
                  style: GoogleFonts.dmSans(
                    fontSize: 12,
                    color: CcColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Group permissions ────────────────────────────────

  /// Group Permissions section. The owner gets a toggle per
  /// permission (Everyone / Only owner); everyone else sees the
  /// current permissions read-only.
  Widget _permissionsSection(BuildContext context, Group group,
      IdentityStore identity, bool isOwner) {
    final perms = group.permissions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Group permissions',
          style: GoogleFonts.nunito(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: CcColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          isOwner
              ? 'Choose who can do what in this group.'
              : 'Set by the group owner.',
          style: GoogleFonts.dmSans(
            fontSize: 12,
            color: CcColors.textMuted,
          ),
        ),
        const SizedBox(height: 12),
        if (isOwner) ...[
          _permissionToggle(
            context, group, identity,
            icon: Icons.chat_bubble_outline_rounded,
            title: 'Send messages',
            subtitle: perms.sendMessagesOnlyOwner
                ? 'Only owner can send.'
                : 'Everyone can send.',
            value: perms.sendMessagesOnlyOwner,
            onChanged: (v) => _applyPermissions(
              context, group, identity,
              perms.copyWith(sendMessagesOnlyOwner: v),
            ),
          ),
          _permissionToggle(
            context, group, identity,
            icon: Icons.edit_rounded,
            title: 'Edit group info',
            subtitle: perms.editInfoOnlyOwner
                ? 'Only owner can change the name / photo.'
                : 'Everyone can change the name / photo.',
            value: perms.editInfoOnlyOwner,
            onChanged: (v) => _applyPermissions(
              context, group, identity,
              perms.copyWith(editInfoOnlyOwner: v),
            ),
          ),
          _permissionToggle(
            context, group, identity,
            icon: Icons.person_add_rounded,
            title: 'Add members',
            subtitle: perms.addMembersOnlyOwner
                ? 'Only owner can add members.'
                : 'Everyone can add members.',
            value: perms.addMembersOnlyOwner,
            onChanged: (v) => _applyPermissions(
              context, group, identity,
              perms.copyWith(addMembersOnlyOwner: v),
            ),
          ),
        ] else ...[
          _permissionReadOnly(
            icon: Icons.chat_bubble_outline_rounded,
            title: 'Send messages',
            value: perms.sendMessagesOnlyOwner,
          ),
          _permissionReadOnly(
            icon: Icons.edit_rounded,
            title: 'Edit group info',
            value: perms.editInfoOnlyOwner,
          ),
          _permissionReadOnly(
            icon: Icons.person_add_rounded,
            title: 'Add members',
            value: perms.addMembersOnlyOwner,
          ),
        ],
      ],
    );
  }

  /// One permission row with an owner-only toggle. Toggling updates
  /// this phone first, then fans a `groupUpdate` packet to every
  /// member so their phones enforce the new set.
  Widget _permissionToggle(
    BuildContext context,
    Group group,
    IdentityStore identity, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: CcGlass.panel(radius: 18),
      child: Row(
        children: [
          Icon(icon, color: CcColors.aquaCyan, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.nunito(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: CcColors.textPrimary,
                  ),
                ),
                Text(
                  subtitle,
                  style: GoogleFonts.dmSans(
                    fontSize: 12,
                    color: CcColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            activeColor: CcColors.aquaCore,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  /// One permission row, read-only: shows Everyone / Only owner.
  Widget _permissionReadOnly({
    required IconData icon,
    required String title,
    required bool value,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: CcGlass.panel(radius: 18),
      child: Row(
        children: [
          Icon(icon, color: CcColors.aquaCyan, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              title,
              style: GoogleFonts.nunito(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: CcColors.textPrimary,
              ),
            ),
          ),
          Text(
            value ? 'Only owner' : 'Everyone',
            style: GoogleFonts.dmSans(
              fontSize: 13,
              color: value
                  ? CcColors.aquaCore
                  : CcColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _applyPermissions(
    BuildContext context,
    Group group,
    IdentityStore identity,
    GroupPermissions next,
  ) async {
    final repo = context.read<ChatRepository>();
    final ble = context.read<BleChatService>();
    await repo.updateGroupPermissions(
      groupId: group.id,
      permissions: next,
    );
    final packet = BlePacket.groupUpdate(
      from: identity.userId,
      name: identity.displayName,
      groupId: group.id,
      ownerId: identity.userId,
      permissions: next,
    );
    for (final memberId in group.members.keys) {
      await ble.sendTo(memberId, packet);
    }
  }

  Widget _memberRow({
    required String name,
    String? badge,
    bool self = false,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: CcGlass.panel(radius: 18),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: CcColors.aquaGradient,
            ),
            child: Center(
              child: Text(
                name.isEmpty ? '?' : name[0].toUpperCase(),
                style: GoogleFonts.nunito(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              style: GoogleFonts.nunito(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: CcColors.textPrimary,
              ),
            ),
          ),
          if (badge != null)
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: CcColors.aquaCore.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                badge,
                style: GoogleFonts.nunito(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: CcColors.aquaCore,
                ),
              ),
            ),
          if (self && badge == null)
            Text(
              'You',
              style: GoogleFonts.dmSans(
                fontSize: 12,
                color: CcColors.textMuted,
              ),
            ),
        ],
      ),
    );
  }

  // ─── Group photo ────────────────────────────────────────

  /// Group avatar: the photo when one is set, otherwise the initial.
  /// Tapping opens the photo sheet — only when [canEdit] (the
  /// edit-info permission): otherwise the camera badge is hidden
  /// and the avatar is not tappable.
  Widget _groupPhoto(BuildContext context, Group group, bool canEdit) {
    final photoPath = group.photoPath;
    final hasPhoto = photoPath != null && File(photoPath).existsSync();
    final avatar = Stack(
      children: [
        if (hasPhoto)
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              image: DecorationImage(
                image: FileImage(File(photoPath)),
                fit: BoxFit.cover,
              ),
            ),
          )
        else
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: CcColors.aquaGradient,
            ),
            child: Center(
              child: Text(
                group.name.isEmpty
                    ? '?'
                    : group.name[0].toUpperCase(),
                style: GoogleFonts.nunito(
                  fontSize: 38,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        if (canEdit)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: CcColors.aquaCore,
                border: Border.all(
                  color: CcColors.deepSea,
                  width: 2,
                ),
              ),
              child: const Icon(
                Icons.camera_alt_rounded,
                color: Colors.white,
                size: 16,
              ),
            ),
          ),
      ],
    );
    if (!canEdit) return avatar;
    return GestureDetector(
      onTap: () => _photoSheet(context, group),
      child: avatar,
    );
  }

  void _photoSheet(BuildContext context, Group group) {
    final hasPhoto = group.photoPath != null;
    showModalBottomSheet(
      context: context,
      backgroundColor: CcColors.deepSea,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              _sheetOption(
                sheetContext,
                icon: Icons.photo_library_rounded,
                title: hasPhoto ? 'Change photo' : 'Choose photo',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _changePhoto(context, group);
                },
              ),
              if (hasPhoto)
                _sheetOption(
                  sheetContext,
                  icon: Icons.delete_outline_rounded,
                  title: 'Remove photo',
                  danger: true,
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await _removePhoto(context, group);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetOption(
    BuildContext context, {
    required IconData icon,
    required String title,
    bool danger = false,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: CcGlass.panel(radius: 18),
        child: Row(
          children: [
            Icon(icon,
                color: danger ? CcColors.errorRed : CcColors.aquaCyan,
                size: 22),
            const SizedBox(width: 14),
            Text(
              title,
              style: GoogleFonts.nunito(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: danger
                    ? CcColors.errorRed
                    : CcColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Picks an image and copies it into app storage as
  /// `group_photo_<groupId>.jpg` (same pattern as the profile photo).
  Future<void> _changePhoto(BuildContext context, Group group) async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      final source = picked?.files.single.path;
      if (source == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final dest = File(p.join(dir.path, 'group_photo_${group.id}.jpg'));
      await File(source).copy(dest.path);
      if (context.mounted) {
        await context
            .read<ChatRepository>()
            .setGroupPhotoPath(group.id, dest.path);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not set photo: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  /// Deletes the photo file and forgets the path.
  Future<void> _removePhoto(BuildContext context, Group group) async {
    final old = group.photoPath;
    await context
        .read<ChatRepository>()
        .clearGroupPhotoPath(group.id);
    if (old != null) {
      try {
        final file = File(old);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }
}
