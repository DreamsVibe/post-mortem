import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../coach/analysis_queue.dart';
import '../services.dart';
import '../theme.dart';
import 'review_screen.dart';

/// Every game waiting for, getting, or finished with a coach review.
class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final queue = services.queue;
    return ListenableBuilder(
      listenable: queue,
      builder: (context, _) {
        final items = queue.items.reversed.toList()
          ..sort((a, b) {
            int rank(QueueItem i) => switch (i.state) {
              QueueState.engine || QueueState.coach => 0,
              QueueState.queued => 1,
              QueueState.failed => 2,
              QueueState.done => 3,
            };
            return rank(a) - rank(b);
          });
        final hasFinished = items.any(
          (i) => i.state == QueueState.done || i.state == QueueState.failed,
        );
        return Scaffold(
          appBar: AppBar(
            title: const Text('Analysis queue'),
            actions: [
              if (hasFinished)
                TextButton(onPressed: queue.clearFinished, child: const Text('Clear finished')),
            ],
          ),
          body: items.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'Nothing in the queue. Open a game and tap "Analyze with Coach" to add it. '
                      'Reviews run one at a time in the background, even while you look at other '
                      'games.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: kIvoryMuted, height: 1.4),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: items.length + 1,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 88),
                  itemBuilder: (context, i) {
                    if (i == items.length) {
                      return const Padding(
                        padding: EdgeInsets.fromLTRB(20, 16, 20, 32),
                        child: Text(
                          'Reviews keep running in the background while this app is open or '
                          'minimized. If the app is closed completely, the queue picks up again '
                          'the next time you open it.',
                          style: TextStyle(color: kIvoryMuted, fontSize: 12.5, height: 1.4),
                        ),
                      );
                    }
                    return _QueueTile(item: items[i]);
                  },
                ),
        );
      },
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({required this.item});

  final QueueItem item;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final game = item.game;
    final side = game.sideOf(services.settings.username) ?? Side.white;
    final color = switch (item.state) {
      QueueState.done => kWin,
      QueueState.failed => kLoss,
      QueueState.queued => kIvoryMuted,
      _ => kAmber,
    };
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ReviewScreen(game: game)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            StaticChessboard(
              size: 56,
              orientation: side,
              fen: game.positions.last.fen,
              settings: StaticChessboardSettings(
                enableCoordinates: false,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${game.white.name} vs ${game.black.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleSmall?.copyWith(color: kIvory),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    item.statusText,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: color),
                  ),
                  if (item.active) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: item.progress,
                      minHeight: 3,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ],
                ],
              ),
            ),
            if (item.state == QueueState.failed)
              IconButton(
                tooltip: 'Try again',
                icon: const Icon(Icons.refresh, color: kAmber),
                onPressed: () => services.queue.retry(item),
              ),
            if (!item.active)
              IconButton(
                tooltip: item.state == QueueState.queued ? 'Remove from queue' : 'Remove',
                icon: const Icon(Icons.close, color: kIvoryMuted),
                onPressed: () => services.queue.remove(item),
              ),
          ],
        ),
      ),
    );
  }
}
