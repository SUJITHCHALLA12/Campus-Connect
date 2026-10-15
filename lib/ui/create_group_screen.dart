import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../ble/ble_transport.dart';
import '../core/constants.dart';
import '../data/chat_repository.dart';
import 'group_chat_screen.dart';
import 'nearby_sheet.dart';

/// Create a group chat: name it, pick members from people this phone
/// has chatted with or is currently linked to, then jump into the
/// group chat. Members who are out of range when a message is sent
/// simply miss that message — there is no server to hold it.
class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _nameController = TextEditingController();
  final Set<String> _selected = {};
  bool _creating = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<ChatRepository>();
    final ble = context.watch<BleChatService>();

    // Candidates: everyone chatted with + everyone currently linked.
    final candidates = <String, String>{};
    for (final c in repo.conversations) {
      candidates[c.peerUserId] = c.peerName;
    }
    for (final link in ble.links) {
      if (link.userId != null) {
        candidates[link.userId!] = link.displayName;
      }
    }
    final ids = candidates.keys.toList()..sort(
        (a, b) => candidates[a]!.compareTo(candidates[b]!));
    final canCreate =
        _nameController.text.trim().isNotEmpty && _selected.isNotEmpty;

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
          'New group',
          style: GoogleFonts.nunito(
            fontWeight: FontWeight.w700,
            color: CcColors.textPrimary,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Group name',
                style: GoogleFonts.dmSans(
                  fontSize: 14,
                  color: CcColors.textMuted,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                decoration: CcGlass.input(radius: 18),
                child: TextField(
                  controller: _nameController,
                  maxLength: 32,
                  textCapitalization: TextCapitalization.words,
                  style: GoogleFonts.dmSans(color: CcColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'e.g. Study Group',
                    hintStyle: GoogleFonts.dmSans(
                        color: CcColors.textMuted),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    counterText: '',
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 16),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Add members (${_selected.length} selected)',
                style: GoogleFonts.dmSans(
                  fontSize: 14,
                  color: CcColors.textMuted,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ids.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'No one to add yet — pair with a nearby phone first.',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.dmSans(
                                  color: CcColors.textMuted,
                                ),
                              ),
                              const SizedBox(height: 16),
                              GestureDetector(
                                onTap: () => showNearbySheet(context),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 20, vertical: 13),
                                  decoration: BoxDecoration(
                                    gradient: CcColors.buttonGradient,
                                    borderRadius:
                                        BorderRadius.circular(18),
                                  ),
                                  child: Text(
                                    'Pair with nearby',
                                    style: GoogleFonts.nunito(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: ids.length,
                        itemBuilder: (_, i) {
                          final id = ids[i];
                          final name = candidates[id]!;
                          final checked = _selected.contains(id);
                          return GestureDetector(
                            onTap: () => setState(() {
                              if (checked) {
                                _selected.remove(id);
                              } else {
                                _selected.add(id);
                              }
                            }),
                            child: Container(
                              margin:
                                  const EdgeInsets.only(bottom: 8),
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
                                        name.isEmpty
                                            ? '?'
                                            : name[0].toUpperCase(),
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
                                  Icon(
                                    checked
                                        ? Icons.check_circle_rounded
                                        : Icons
                                            .radio_button_unchecked_rounded,
                                    color: checked
                                        ? CcColors.aquaCore
                                        : CcColors.textMuted,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: !canCreate || _creating
                    ? null
                    : () async {
                        setState(() => _creating = true);
                        try {
                          final members = {
                            for (final id in _selected)
                              id: candidates[id]!,
                          };
                          final group = await repo.createGroup(
                            name: _nameController.text.trim(),
                            members: members,
                          );
                          if (context.mounted) {
                            Navigator.of(context).pushReplacement(
                              MaterialPageRoute(
                                builder: (_) =>
                                    GroupChatScreen(group: group),
                              ),
                            );
                          }
                        } catch (e) {
                          // Creation used to fail silently — the tap
                          // just did nothing. Surface the real error
                          // so a broken create is diagnosable.
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                    'Could not create group: $e'),
                                duration:
                                    const Duration(seconds: 4),
                              ),
                            );
                          }
                        } finally {
                          if (mounted) {
                            setState(() => _creating = false);
                          }
                        }
                      },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 17),
                  decoration: BoxDecoration(
                    gradient: CcColors.buttonGradient,
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: canCreate ? CcColors.aquaGlow : null,
                  ),
                  child: Center(
                    child: Text(
                      _creating ? 'Creating…' : 'Create group',
                      style: GoogleFonts.nunito(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: canCreate
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
