import 'package:flutter/material.dart';

/// One per-chat theme: a background tint for the chat screen plus the
/// gradient used for the user's own message bubbles. Themes are
/// per-conversation — picking one changes only that 1:1 chat, never
/// the whole app. Group chats always use the default (Ocean) theme.
class ChatTheme {
  final String id;
  final String name;
  final Color backgroundTint;
  final LinearGradient bubbleGradient;
  final Color accent;

  const ChatTheme({
    required this.id,
    required this.name,
    required this.backgroundTint,
    required this.bubbleGradient,
    required this.accent,
  });
}

const List<ChatTheme> chatThemes = [
  ChatTheme(
    id: 'ocean',
    name: 'Ocean',
    backgroundTint: Color(0x2200C2FF),
    bubbleGradient: LinearGradient(
      colors: [Color(0x6600C2FF), Color(0x4DA855F7)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    accent: Color(0xFF00C2FF),
  ),
  ChatTheme(
    id: 'sunset',
    name: 'Sunset',
    backgroundTint: Color(0x22FF8A00),
    bubbleGradient: LinearGradient(
      colors: [Color(0x66FF8A00), Color(0x4DFF3D68)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    accent: Color(0xFFFF8A00),
  ),
  ChatTheme(
    id: 'forest',
    name: 'Forest',
    backgroundTint: Color(0x2210B981),
    bubbleGradient: LinearGradient(
      colors: [Color(0x6610B981), Color(0x4D14B8A6)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    accent: Color(0xFF10B981),
  ),
  ChatTheme(
    id: 'grape',
    name: 'Grape',
    backgroundTint: Color(0x228B5CF6),
    bubbleGradient: LinearGradient(
      colors: [Color(0x668B5CF6), Color(0x4DD946EF)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    accent: Color(0xFF8B5CF6),
  ),
  ChatTheme(
    id: 'rose',
    name: 'Rose',
    backgroundTint: Color(0x22F43F5E),
    bubbleGradient: LinearGradient(
      colors: [Color(0x66F43F5E), Color(0x4DFB7185)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    accent: Color(0xFFF43F5E),
  ),
  ChatTheme(
    id: 'mono',
    name: 'Mono',
    backgroundTint: Color(0x2294A3B8),
    bubbleGradient: LinearGradient(
      colors: [Color(0x665E6B7A), Color(0x4D475569)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    accent: Color(0xFF94A3B8),
  ),
];

/// The default theme (Ocean) — also the fallback for unknown ids.
ChatTheme get defaultChatTheme => chatThemes.first;

ChatTheme chatThemeById(String? id) {
  for (final t in chatThemes) {
    if (t.id == id) return t;
  }
  return defaultChatTheme;
}
