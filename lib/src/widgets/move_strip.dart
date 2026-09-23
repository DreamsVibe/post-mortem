import 'package:flutter/material.dart';

import '../game_record.dart';
import '../theme.dart';

/// Horizontally scrolling list of the game's moves; the current one is highlighted and kept in
/// view.
class MoveStrip extends StatefulWidget {
  const MoveStrip({
    super.key,
    required this.game,
    required this.currentPly,
    required this.onSelectPly,
    this.colors = const {},
    this.keyMoments = const {},
  });

  final GameRecord game;
  final int currentPly;
  final void Function(int ply) onSelectPly;

  /// Accent color per ply (move quality).
  final Map<int, Color> colors;
  final Set<int> keyMoments;

  @override
  State<MoveStrip> createState() => _MoveStripState();
}

class _MoveStripState extends State<MoveStrip> {
  static const _itemWidth = 76.0;
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant MoveStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentPly != widget.currentPly) _center();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _center(animate: false));
  }

  void _center({bool animate = true}) {
    if (!_scroll.hasClients) return;
    final viewport = _scroll.position.viewportDimension;
    final target = ((widget.currentPly - 1) * _itemWidth - viewport / 2 + _itemWidth / 2).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    if (animate) {
      _scroll.animateTo(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    } else {
      _scroll.jumpTo(target);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    return SizedBox(
      height: 40,
      child: ListView.builder(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: game.plyCount,
        itemExtent: _itemWidth,
        itemBuilder: (context, i) {
          final ply = i + 1;
          final selected = ply == widget.currentPly;
          final accent = widget.colors[ply];
          final isKey = widget.keyMoments.contains(ply);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Material(
              color: selected ? kAmber : kInkRaised,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => widget.onSelectPly(ply),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (isKey)
                      Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: Icon(Icons.star, size: 11, color: selected ? kInk : kAmber),
                      ),
                    Flexible(
                      child: Text(
                        game.moveLabel(ply).replaceFirst('… ', '…'),
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: selected ? kInk : (accent ?? kIvory),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
