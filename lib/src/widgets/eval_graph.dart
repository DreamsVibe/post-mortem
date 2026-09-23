import 'package:flutter/material.dart';

import '../engine/eval.dart';
import '../theme.dart';

/// Win-chance graph across the whole game. Tap or drag to jump to a move.
class EvalGraph extends StatelessWidget {
  const EvalGraph({
    super.key,
    required this.evals,
    required this.plyCount,
    required this.currentPly,
    required this.onSelectPly,
    this.markers = const {},
    this.keyMoments = const {},
  });

  /// Eval per position (index = ply); may be shorter than plyCount + 1 while analyzing.
  final List<Eval> evals;
  final int plyCount;
  final int currentPly;
  final void Function(int ply) onSelectPly;

  /// Plies to mark with a colored dot (mistakes and blunders).
  final Map<int, Color> markers;

  /// Plies the coach flagged as key moments.
  final Set<int> keyMoments;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        void select(double dx) {
          if (plyCount == 0) return;
          final ply = (dx / width * plyCount).round().clamp(0, plyCount);
          onSelectPly(ply);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => select(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => select(d.localPosition.dx),
          child: CustomPaint(
            size: Size(width, 64),
            painter: _GraphPainter(
              values: [for (final e in evals) e.whiteWinChance],
              plyCount: plyCount,
              currentPly: currentPly,
              markers: markers,
              keyMoments: keyMoments,
            ),
          ),
        );
      },
    );
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.values,
    required this.plyCount,
    required this.currentPly,
    required this.markers,
    required this.keyMoments,
  });

  final List<double> values;
  final int plyCount;
  final int currentPly;
  final Map<int, Color> markers;
  final Set<int> keyMoments;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8));
    canvas.drawRRect(r, Paint()..color = kInkRaised);
    canvas.save();
    canvas.clipRRect(r);

    final mid = size.height / 2;
    double x(int ply) => plyCount == 0 ? 0 : ply / plyCount * size.width;
    double y(double v) => mid - v * (mid - 4);

    if (values.isNotEmpty) {
      final area = Path()..moveTo(x(0), mid);
      for (var i = 0; i < values.length; i++) {
        area.lineTo(x(i), y(values[i]));
      }
      area.lineTo(x(values.length - 1), mid);
      area.close();
      canvas.drawPath(area, Paint()..color = kIvory.withValues(alpha: 0.18));

      final line = Path()..moveTo(x(0), y(values[0]));
      for (var i = 1; i < values.length; i++) {
        line.lineTo(x(i), y(values[i]));
      }
      canvas.drawPath(
        line,
        Paint()
          ..color = kIvory.withValues(alpha: 0.8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    canvas.drawLine(
      Offset(0, mid),
      Offset(size.width, mid),
      Paint()
        ..color = Colors.white24
        ..strokeWidth = 1,
    );

    for (final ply in keyMoments) {
      if (ply > plyCount) continue;
      canvas.drawLine(
        Offset(x(ply), 0),
        Offset(x(ply), size.height),
        Paint()
          ..color = kAmber.withValues(alpha: 0.35)
          ..strokeWidth = 2,
      );
    }

    markers.forEach((ply, color) {
      if (ply < values.length) {
        canvas.drawCircle(Offset(x(ply), y(values[ply])), 3.5, Paint()..color = color);
      }
    });

    final cx = x(currentPly);
    canvas.drawLine(
      Offset(cx, 0),
      Offset(cx, size.height),
      Paint()
        ..color = kAmber
        ..strokeWidth = 2,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GraphPainter old) =>
      old.values.length != values.length ||
      old.currentPly != currentPly ||
      old.markers.length != markers.length ||
      old.keyMoments.length != keyMoments.length;
}
