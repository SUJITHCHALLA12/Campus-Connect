import 'dart:async';
import 'dart:io';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
// google_fonts also exports a `Config` — hide it so `Config(...)`
// below unambiguously means the emoji picker's config.
import 'package:google_fonts/google_fonts.dart' hide Config;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../core/theme/cc_colors.dart';
import '../../core/theme/cc_glass.dart';

/// WhatsApp-style message composer in the logo colours.
///
/// Layout: a rounded input pill (emoji · Message · attach · camera) and
/// a circular action button. The action button shows **send** while
/// there is text, and **mic** when the field is empty — tapping mic
/// starts a voice recording (tap ✓ to send, ✕ to discard, 60 s cap).
/// The emoji button opens an inline emoji picker above the composer.
///
/// Voice recording lives here; the chat screen owns sending: when a
/// recording finishes, [onVoiceMessage] gets the recorded .m4a file.
/// Passing `onVoiceMessage: null` (group chats) hides the mic and
/// always shows the send button.
class GlassInputBar extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final bool isSending;
  final bool enabled;
  final VoidCallback? onAttachImage;
  final VoidCallback? onAttachFile;
  final ValueChanged<File>? onVoiceMessage;

  const GlassInputBar({
    super.key,
    required this.controller,
    required this.onSend,
    this.isSending = false,
    this.enabled = true,
    this.onAttachImage,
    this.onAttachFile,
    this.onVoiceMessage,
  });

  @override
  State<GlassInputBar> createState() => _GlassInputBarState();
}

class _GlassInputBarState extends State<GlassInputBar> {
  final _focusNode = FocusNode();
  final _recorder = AudioRecorder();
  bool _hasText = false;
  bool _showEmoji = false;
  bool _recording = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;

  @override
  void initState() {
    super.initState();
    _hasText = widget.controller.text.isNotEmpty;
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _recordTimer?.cancel();
    _recorder.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final has = widget.controller.text.isNotEmpty;
    if (has != _hasText && mounted) setState(() => _hasText = has);
  }

  void _toggleEmoji() {
    if (_showEmoji) {
      setState(() => _showEmoji = false);
      _focusNode.requestFocus();
    } else {
      _focusNode.unfocus();
      setState(() => _showEmoji = true);
    }
  }

  void _insertEmoji(Emoji emoji) {
    final controller = widget.controller;
    final text = controller.text;
    final selection = controller.selection;
    final start = selection.start < 0 ? text.length : selection.start;
    final end = selection.end < 0 ? text.length : selection.end;
    final newText = text.replaceRange(start, end, emoji.emoji);
    controller.value = TextEditingValue(
      text: newText,
      selection:
          TextSelection.collapsed(offset: start + emoji.emoji.length),
    );
  }

  void _deleteEmojiChar() {
    final controller = widget.controller;
    final text = controller.text;
    final selection = controller.selection;
    final cursor = selection.start < 0 ? text.length : selection.start;
    if (cursor == 0 || text.isEmpty) return;
    // Emoji are UTF-16 surrogate pairs — delete both units.
    var deleteCount = 1;
    if (cursor >= 2) {
      final prev = text.codeUnitAt(cursor - 1);
      if (prev >= 0xDC00 && prev <= 0xDFFF) deleteCount = 2;
    }
    final newText =
        text.replaceRange(cursor - deleteCount, cursor, '');
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: cursor - deleteCount),
    );
  }

  Future<void> _startRecording() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Microphone permission is needed for voice messages.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    final voiceDir = Directory(p.join(dir.path, 'voice'));
    await voiceDir.create(recursive: true);
    final path = p.join(voiceDir.path,
        'voice_${DateTime.now().millisecondsSinceEpoch}.m4a');
    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 32000,
          sampleRate: 22050,
        ),
        path: path,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not start recording.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    setState(() {
      _recording = true;
      _recordSeconds = 0;
    });
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recordSeconds++);
      if (_recordSeconds >= 60) _stopRecording(send: true);
    });
  }

  Future<void> _stopRecording({required bool send}) async {
    _recordTimer?.cancel();
    _recordTimer = null;
    final path = await _recorder.stop();
    if (mounted) setState(() => _recording = false);
    if (path == null) return;
    final file = File(path);
    if (send) {
      widget.onVoiceMessage?.call(file);
    } else {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  String _formatDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        8,
        8,
        8,
        8 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        color: CcColors.abyss.withValues(alpha: 0.7),
        border: Border(
          top: BorderSide(
            color: CcColors.glassBorder.withValues(alpha: 0.5),
            width: 1,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_showEmoji && !_recording)
            SizedBox(
              height: 250,
              child: EmojiPicker(
                // 4.x callback passes (category, emoji) — both params
                // required; a one-param lambda binds to Category?.
                onEmojiSelected: (category, emoji) =>
                    _insertEmoji(emoji),
                onBackspacePressed: _deleteEmojiChar,
                config: Config(
                  bgColor: CcColors.deepSea,
                  indicatorColor: CcColors.aquaCore,
                  iconColorSelected: CcColors.aquaCore,
                ),
              ),
            ),
          if (_recording) _recordingRow() else _composerRow(),
        ],
      ),
    );
  }

  Widget _composerRow() {
    final showSend =
        _hasText || widget.onVoiceMessage == null || widget.isSending;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Container(
            decoration: CcGlass.input(radius: 28),
            child: Row(
              children: [
                const SizedBox(width: 4),
                IconButton(
                  onPressed: _toggleEmoji,
                  icon: Icon(
                    _showEmoji
                        ? Icons.keyboard_rounded
                        : Icons.emoji_emotions_outlined,
                    color: _showEmoji
                        ? CcColors.aquaCore
                        : CcColors.textMuted,
                    size: 24,
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    focusNode: _focusNode,
                    enabled: widget.enabled,
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.send,
                    style: GoogleFonts.dmSans(
                        color: CcColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Message',
                      hintStyle: GoogleFonts.dmSans(
                          color: CcColors.textMuted),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onTap: () {
                      if (_showEmoji) {
                        setState(() => _showEmoji = false);
                      }
                    },
                    onSubmitted: (_) => widget.onSend(),
                  ),
                ),
                if (widget.onAttachFile != null)
                  IconButton(
                    onPressed: widget.onAttachFile,
                    icon: const Icon(
                      Icons.attach_file_rounded,
                      color: CcColors.textSecondary,
                      size: 22,
                    ),
                  ),
                if (widget.onAttachImage != null)
                  IconButton(
                    onPressed: widget.onAttachImage,
                    icon: const Icon(
                      Icons.camera_alt_outlined,
                      color: CcColors.textSecondary,
                      size: 22,
                    ),
                  ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        _actionButton(showSend: showSend),
      ],
    );
  }

  Widget _actionButton({required bool showSend}) {
    return GestureDetector(
      onTap: widget.isSending
          ? null
          : showSend
              ? widget.onSend
              : _startRecording,
      child: Container(
        width: 52,
        height: 52,
        decoration: CcGlass.buttonPrimary(radius: 26),
        child: widget.isSending
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  showSend ? Icons.send_rounded : Icons.mic_rounded,
                  key: ValueKey(showSend ? 'send' : 'mic'),
                  color: Colors.white,
                  size: 24,
                ),
              ),
      ),
    );
  }

  Widget _recordingRow() {
    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.red,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          _formatDuration(_recordSeconds),
          style: GoogleFonts.dmSans(
            fontSize: 16,
            color: CcColors.textPrimary,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          'Recording…',
          style: GoogleFonts.dmSans(
            fontSize: 13,
            color: CcColors.textMuted,
          ),
        ),
        const Spacer(),
        IconButton(
          onPressed: () => _stopRecording(send: false),
          icon: const Icon(
            Icons.close_rounded,
            color: CcColors.textMuted,
          ),
        ),
        GestureDetector(
          onTap: () => _stopRecording(send: true),
          child: Container(
            width: 52,
            height: 52,
            decoration: CcGlass.buttonPrimary(radius: 26),
            child: const Icon(Icons.check_rounded,
                color: Colors.white, size: 26),
          ),
        ),
      ],
    );
  }
}
