/// Small time formatters for chat UI.
String formatListTime(int ts) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ts);
  final now = DateTime.now();
  final diff = now.difference(dt);
  if (diff.inDays == 0) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
  }
  if (diff.inDays < 7) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[dt.weekday - 1];
  }
  return '${dt.day}/${dt.month}/${dt.year % 100}';
}
