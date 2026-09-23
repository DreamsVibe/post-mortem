import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../game_record.dart';
import '../settings.dart';
import '../theme.dart';

/// Basic game viewer: step through the moves on the board.
///
/// This is the starting point for the full review screen (engine analysis,
/// eval graph and the coach come in the next steps).
class GameScreen extends StatefulWidget {
  const GameScreen({super.key, required this.game, required this.settings});

  final GameRecord game;
  final AppSettings settings;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  late int _ply = widget.game.plyCount;
  late Side _orientation = widget.game.sideOf(widget.settings.username) ?? Side.white;

  void _go(int ply) => setState(() => _ply = ply.clamp(0, widget.game.plyCount));

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final text = Theme.of(context).textTheme;
    final top = _orientation == Side.white ? game.black : game.white;
    final bottom = _orientation == Side.white ? game.white : game.black;
    final lastMove = _ply > 0 ? game.moves[_ply - 1] : null;

    return Scaffold(
      appBar: AppBar(
        title: Text('${game.white.name} vs ${game.black.name}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Flip board',
            icon: const Icon(Icons.swap_vert),
            onPressed: () => setState(() => _orientation = _orientation.opposite),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PlayerLine(player: top),
            LayoutBuilder(
              builder: (context, constraints) => GestureDetector(
                onHorizontalDragEnd: (d) {
                  final v = d.primaryVelocity ?? 0;
                  if (v < -200) _go(_ply + 1);
                  if (v > 200) _go(_ply - 1);
                },
                child: StaticChessboard(
                  size: constraints.maxWidth,
                  orientation: _orientation,
                  fen: game.positions[_ply].fen,
                  lastMove: lastMove,
                  settings: const StaticChessboardSettings(
                    colorScheme: ChessboardColorScheme.brown,
                  ),
                ),
              ),
            ),
            _PlayerLine(player: bottom),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      game.moveLabel(_ply),
                      style: text.titleLarge?.copyWith(color: kIvory),
                    ),
                  ),
                  Text(
                    _ply == game.plyCount ? game.result.label : '${_ply} / ${game.plyCount}',
                    style: text.titleMedium?.copyWith(color: kIvoryMuted),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    tooltip: 'Start',
                    iconSize: 32,
                    icon: const Icon(Icons.first_page),
                    onPressed: _ply > 0 ? () => _go(0) : null,
                  ),
                  IconButton(
                    tooltip: 'Previous move',
                    iconSize: 40,
                    icon: const Icon(Icons.chevron_left),
                    onPressed: _ply > 0 ? () => _go(_ply - 1) : null,
                  ),
                  IconButton(
                    tooltip: 'Next move',
                    iconSize: 40,
                    icon: const Icon(Icons.chevron_right),
                    onPressed: _ply < game.plyCount ? () => _go(_ply + 1) : null,
                  ),
                  IconButton(
                    tooltip: 'End',
                    iconSize: 32,
                    icon: const Icon(Icons.last_page),
                    onPressed: _ply < game.plyCount ? () => _go(game.plyCount) : null,
                  ),
                ],
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                onPressed: null,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                icon: const Icon(Icons.school_outlined),
                label: const Text('Analyze with Coach — coming soon'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayerLine extends StatelessWidget {
  const _PlayerLine({required this.player});

  final GamePlayer player;

  @override
  Widget build(BuildContext context) {
    final diff = player.ratingDiff;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(player.isAi ? Icons.memory : Icons.person_outline, size: 18, color: kIvoryMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(player.display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kIvory, fontSize: 15)),
          ),
          if (diff != null)
            Text(diff >= 0 ? '+$diff' : '$diff',
                style: TextStyle(color: diff >= 0 ? kWin : kLoss, fontSize: 14)),
        ],
      ),
    );
  }
}
