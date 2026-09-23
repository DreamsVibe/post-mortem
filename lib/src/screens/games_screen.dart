import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../game_record.dart';
import '../lichess_client.dart';
import '../settings.dart';
import '../theme.dart';
import 'game_screen.dart';
import 'settings_screen.dart';

/// Recent games of a player: yours by default, or anyone you look up.
class GamesScreen extends StatefulWidget {
  const GamesScreen({
    super.key,
    required this.settings,
    required this.lichess,
    this.username,
  });

  final AppSettings settings;
  final LichessClient lichess;

  /// Whose games to show. Null means the linked account.
  final String? username;

  @override
  State<GamesScreen> createState() => _GamesScreenState();
}

class _GamesScreenState extends State<GamesScreen> {
  late Future<List<GameRecord>> _games;

  bool get _isOwn => widget.username == null;
  String get _player => widget.username ?? widget.settings.username ?? '';

  @override
  void initState() {
    super.initState();
    _games = widget.lichess.userGames(_player);
  }

  @override
  void didUpdateWidget(covariant GamesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.username != widget.username) _refresh();
  }

  Future<void> _refresh() async {
    final next = widget.lichess.userGames(_player);
    setState(() => _games = next);
    try {
      await next;
    } catch (_) {}
  }

  void _openGame(GameRecord game) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GameScreen(game: game, settings: widget.settings),
    ));
  }

  Future<void> _lookUpPlayer() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _LookUpDialog(),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final found = await widget.lichess.lookUpUser(name);
      if (!mounted) return;
      if (found == null) {
        messenger.showSnackBar(const SnackBar(content: Text('No Lichess player with that username.')));
        return;
      }
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => GamesScreen(settings: widget.settings, lichess: widget.lichess, username: found),
      ));
    } on LichessException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _openLinkOrPgn() async {
    final input = await showDialog<String>(
      context: context,
      builder: (context) => const _OpenGameDialog(),
    );
    if (input == null || input.trim().isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final id = parseLichessGameId(input);
      final GameRecord game;
      if (id != null && !input.contains('[')) {
        game = await widget.lichess.game(id);
      } else {
        game = GameRecord.fromPgn(input);
      }
      if (!mounted) return;
      _openGame(game);
    } on LichessException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isOwn ? 'Your games' : "$_player's games"),
        actions: [
          IconButton(
            tooltip: 'Look up a player',
            icon: const Icon(Icons.person_search_outlined),
            onPressed: _lookUpPlayer,
          ),
          if (_isOwn)
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SettingsScreen(settings: widget.settings, lichess: widget.lichess),
              )),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openLinkOrPgn,
        icon: const Icon(Icons.link),
        label: const Text('Open link or PGN'),
      ),
      body: FutureBuilder<List<GameRecord>>(
        future: _games,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            final message = snap.error is LichessException
                ? (snap.error as LichessException).message
                : 'Something went wrong loading games.';
            return _Message(text: message, actionLabel: 'Try again', onAction: _refresh);
          }
          final games = snap.data ?? const [];
          if (games.isEmpty) {
            return _Message(
              text: 'No finished standard games yet for $_player.',
              actionLabel: 'Refresh',
              onAction: _refresh,
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: games.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 88),
              itemBuilder: (context, i) => _GameTile(
                game: games[i],
                player: _player,
                onTap: () => _openGame(games[i]),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GameTile extends StatelessWidget {
  const _GameTile({required this.game, required this.player, required this.onTap});

  final GameRecord game;
  final String player;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final side = game.sideOf(player) ?? Side.white;
    final opponent = game.opponentOf(side);
    final outcome = game.outcomeFor(side);
    final outcomeColor = switch (outcome) {
      'Won' => kWin,
      'Lost' => kLoss,
      _ => kIvoryMuted,
    };
    final details = [
      if (game.speed != null) _capitalize(game.speed!),
      if (game.openingName != null) game.openingName!,
      if (game.playedAt != null) timeAgo(game.playedAt!),
    ].join(' · ');

    return InkWell(
      onTap: onTap,
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
                colorScheme: ChessboardColorScheme.brown,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('vs ${opponent.display}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleMedium?.copyWith(color: kIvory)),
                  const SizedBox(height: 2),
                  Text(details,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: kIvoryMuted)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(outcome ?? game.result.label,
                style: text.labelLarge?.copyWith(color: outcomeColor, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.actionLabel, required this.onAction});

  final String text;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: kIvoryMuted)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}

class _LookUpDialog extends StatefulWidget {
  const _LookUpDialog();

  @override
  State<_LookUpDialog> createState() => _LookUpDialogState();
}

class _LookUpDialogState extends State<_LookUpDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Look up a player'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        decoration: const InputDecoration(hintText: 'Lichess username'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Show games'),
        ),
      ],
    );
  }
}

class _OpenGameDialog extends StatefulWidget {
  const _OpenGameDialog();

  @override
  State<_OpenGameDialog> createState() => _OpenGameDialogState();
}

class _OpenGameDialogState extends State<_OpenGameDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Open a game'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        minLines: 3,
        maxLines: 8,
        decoration: const InputDecoration(
          hintText: 'Paste a Lichess game link, or a full PGN',
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Open'),
        ),
      ],
    );
  }
}

String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

String timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays < 30) return d.inDays == 1 ? 'yesterday' : '${d.inDays} days ago';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${months[t.month - 1]} ${t.day}, ${t.year}';
}
