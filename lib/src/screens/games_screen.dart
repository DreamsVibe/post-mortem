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
  static const _pageSize = 50;

  final _scroll = ScrollController();
  final List<GameRecord> _games = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  String? _moreError;

  /// Bumped on refresh so answers to stale requests are ignored.
  int _generation = 0;

  bool get _isOwn => widget.username == null;
  String get _player => widget.username ?? widget.settings.username ?? '';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _refresh();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant GamesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.username != widget.username) _refresh();
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 600) _loadMore();
  }

  Future<void> _refresh() async {
    final gen = ++_generation;
    setState(() {
      _loading = _games.isEmpty;
      _error = null;
      _moreError = null;
    });
    try {
      final page = await widget.lichess.userGames(_player, max: _pageSize);
      if (!mounted || gen != _generation) return;
      setState(() {
        _games
          ..clear()
          ..addAll(page.games);
        _hasMore = page.fetched >= _pageSize;
        _loading = false;
      });
    } on LichessException catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _games.isEmpty || _moreError != null) return;
    final gen = _generation;
    final oldest = _games.last.playedAt;
    if (oldest == null) {
      setState(() => _hasMore = false);
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final page = await widget.lichess.userGames(_player, max: _pageSize, until: oldest);
      if (!mounted || gen != _generation) return;
      setState(() {
        _games.addAll(page.games);
        _hasMore = page.fetched >= _pageSize;
        _loadingMore = false;
      });
    } on LichessException catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _moreError = e.message;
        _loadingMore = false;
      });
    }
  }

  void _retryMore() {
    setState(() => _moreError = null);
    _loadMore();
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
      body: Builder(
        builder: (context) {
          if (_loading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_error != null && _games.isEmpty) {
            return _Message(text: _error!, actionLabel: 'Try again', onAction: _refresh);
          }
          if (_games.isEmpty) {
            return _Message(
              text: 'No finished standard games yet for $_player.',
              actionLabel: 'Refresh',
              onAction: _refresh,
            );
          }
          final days = groupByDay(_games);
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.builder(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: days.length + 1,
              itemBuilder: (context, i) {
                if (i == days.length) {
                  return _ListFooter(
                    loading: _loadingMore,
                    hasMore: _hasMore,
                    error: _moreError,
                    count: _games.length,
                    onLoadMore: _moreError != null ? _retryMore : _loadMore,
                  );
                }
                final day = days[i];
                return _DaySection(
                  key: PageStorageKey<DateTime>(day.date),
                  day: day,
                  player: _player,
                  initiallyExpanded: i == 0,
                  onOpen: _openGame,
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// All games played on one calendar day (in the phone's time zone).
class GameDay {
  GameDay(this.date, this.games);

  final DateTime date;
  final List<GameRecord> games;
}

/// Groups games, already sorted newest first, into days. Games with no date go last.
List<GameDay> groupByDay(List<GameRecord> games) {
  final days = <GameDay>[];
  final undated = <GameRecord>[];
  for (final g in games) {
    final t = g.playedAt?.toLocal();
    if (t == null) {
      undated.add(g);
      continue;
    }
    final date = DateTime(t.year, t.month, t.day);
    if (days.isNotEmpty && days.last.date == date) {
      days.last.games.add(g);
    } else {
      days.add(GameDay(date, [g]));
    }
  }
  if (undated.isNotEmpty) days.add(GameDay(DateTime(1970), undated));
  return days;
}

String dayLabel(DateTime date) {
  if (date.year == 1970) return 'Undated';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(date).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final base = '${weekdays[date.weekday - 1]}, ${months[date.month - 1]} ${date.day}';
  return date.year == now.year ? base : '$base, ${date.year}';
}

/// A collapsible day header with the day's record, and its games underneath.
class _DaySection extends StatelessWidget {
  const _DaySection({
    super.key,
    required this.day,
    required this.player,
    required this.initiallyExpanded,
    required this.onOpen,
  });

  final GameDay day;
  final String player;
  final bool initiallyExpanded;
  final void Function(GameRecord) onOpen;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    var won = 0, lost = 0, drawn = 0;
    for (final g in day.games) {
      final side = g.sideOf(player);
      if (side == null) continue;
      switch (g.outcomeFor(side)) {
        case 'Won':
          won++;
        case 'Lost':
          lost++;
        case 'Draw':
          drawn++;
      }
    }
    final count = day.games.length;

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        maintainState: true,
        backgroundColor: kInk,
        collapsedBackgroundColor: kInkRaised,
        iconColor: kAmber,
        collapsedIconColor: kIvoryMuted,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: EdgeInsets.zero,
        title: Text(dayLabel(day.date),
            style: text.titleMedium?.copyWith(color: kIvory, fontWeight: FontWeight.w600)),
        subtitle: Text.rich(
          TextSpan(
            style: text.bodySmall?.copyWith(color: kIvoryMuted),
            children: [
              TextSpan(text: count == 1 ? '1 game' : '$count games'),
              if (won + lost + drawn > 0) ...[
                const TextSpan(text: '  ·  '),
                TextSpan(text: '${won}W', style: const TextStyle(color: kWin)),
                const TextSpan(text: ' '),
                TextSpan(text: '${lost}L', style: const TextStyle(color: kLoss)),
                TextSpan(text: ' ${drawn}D'),
              ],
            ],
          ),
        ),
        children: [
          for (var i = 0; i < day.games.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 88),
            _GameTile(game: day.games[i], player: player, onTap: () => onOpen(day.games[i])),
          ],
        ],
      ),
    );
  }
}

class _ListFooter extends StatelessWidget {
  const _ListFooter({
    required this.loading,
    required this.hasMore,
    required this.error,
    required this.count,
    required this.onLoadMore,
  });

  final bool loading;
  final bool hasMore;
  final String? error;
  final int count;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: kIvoryMuted);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Center(
        child: loading
            ? const Column(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('Loading older games…', style: TextStyle(color: kIvoryMuted)),
                ],
              )
            : error != null
                ? Column(
                    children: [
                      Text(error!, textAlign: TextAlign.center, style: muted),
                      const SizedBox(height: 8),
                      OutlinedButton(onPressed: onLoadMore, child: const Text('Try again')),
                    ],
                  )
                : hasMore
                    ? OutlinedButton(onPressed: onLoadMore, child: const Text('Load older games'))
                    : Text('All $count games loaded', style: muted),
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
      if (game.playedAt != null) clockTime(game.playedAt!.toLocal()),
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

/// "3:42 PM" style time of day.
String clockTime(DateTime t) {
  final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final minute = t.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${t.hour < 12 ? 'AM' : 'PM'}';
}
