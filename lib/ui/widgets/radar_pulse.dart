import 'package:flutter/material.dart';

import '../../core/theme/cc_colors.dart';

/// Expanding-ring "sonar" animation for the Nearby tab header —
/// a Campus Connect original in bioluminescent style.
class RadarPulse extends StatefulWidget {
  final double size;

  const RadarPulse({super.key, this.size = 120});

  @override
  State<RadarPulse> createState() => _RadarPulseState();
}

class _RadarPulseState extends State<RadarPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, __) => CustomPaint(
          painter: _RadarPainter(_controller.value),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final double progress;

  _RadarPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    // Three staggered expanding rings.
    for (var i = 0; i < 3; i++) {
      final p = (progress + i / 3) % 1.0;
      final radius = maxRadius * p;
      final alpha = (1 - p) * 0.5;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = CcColors.aquaCyan.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    // Core dot.
    canvas.drawCircle(
      center,
      10,
      Paint()
        ..shader = const RadialGradient(
          colors: [CcColors.aquaCyan, CcColors.aquaCore],
        ).createShader(Rect.fromCircle(center: center, radius: 10)),
    );
    // Bluetooth glyph.
    final glyph = TextSpan(
      text: String.fromCharCode(Icons.bluetooth.codePoint),
      style: TextStyle(
        fontFamily: Icons.bluetooth.fontFamily,
        fontSize: 14,
        color: Colors.white,
      ),
    );
    final tp = TextPainter(
        text: glyph, textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(
        canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.progress != progress;
}
