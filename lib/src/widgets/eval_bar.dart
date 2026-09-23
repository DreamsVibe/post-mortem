import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../engine/eval.dart';
import '../theme.dart';

/// Vertical bar beside the board showing who's better.
class EvalBar extends StatelessWidget {
  const EvalBar({super.key, required this.eval, required this.orientation, required this.height});

  final Eval? eval;
  final Side orientation;
  final double height;

  @override
  Widget build(BuildContext context) {
    final wc = eval?.whiteWinChance ?? 0;
    final whiteShare = ((wc + 1) / 2).clamp(0.02, 0.98);
    final whiteAtBottom = orientation == Side.white;
    final bottomShare = whiteAtBottom ? whiteShare : 1 - whiteShare;
    final label = eval?.label ?? '';
    return SizedBox(
      width: 16,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: Stack(
          children: [
            Container(color: whiteAtBottom ? const Color(0xFF3A3632) : kIvory),
            Align(
              alignment: Alignment.bottomCenter,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                height: height * bottomShare,
                color: whiteAtBottom ? kIvory : const Color(0xFF3A3632),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: height / 2 - 0.5,
              child: Container(height: 1, color: kAmber.withValues(alpha: 0.6)),
            ),
            if (label.isNotEmpty)
              Align(
                alignment: (wc >= 0) == whiteAtBottom ? Alignment.bottomCenter : Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: wc >= 0 ? kInk : kIvory,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
