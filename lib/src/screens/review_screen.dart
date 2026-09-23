import 'dart:async';

import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../engine/eval.dart';
import '../engine/game_analysis.dart';
import '../engine/stockfish_engine.dart';
import '../game_record.dart';
import '../services.dart';
import '../theme.dart';
import '../widgets/eval_bar.dart';
import '../widgets/eval_graph.dart';
import '../widgets/move_strip.dart';

const kInaccuracy = Color(0xFFE6C45A);
const kMistake = Color(0xFFE8934A);
const kBlunder = Color(0xFFE0605A);

Color? qualityColor(MoveQuality? q) => switch (q) {
  MoveQuality.inaccuracy => kInaccuracy,
  MoveQuality.mistake => kMistake,
  MoveQuality.blunder => kBlunder,
  _ => null,
};

/// A move played on the board away from the game's own moves.
class VariationMove {
  const VariationMove(this.move, this.san, this.after);

  final Move move;
  final String san;
  final Position after;
}

/// The review screen: board, Stockfish analysis, eval bar and graph, and move navigation.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.game});

  final GameRecord game;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  GameRecord get game => widget.game;

  late int _ply = 0;
  late Side _orientation = game.sideOf(services.settings.username) ?? Side.white;

  GameAnalysis? _analysis;
  StreamSubscription<GameAnalysis>? _analysisSub;
  String? _engineError;

  // Exploration away from the game's moves.
  int? _branchPly;
  final List<VariationMove> _variation = [];
  PositionEval? _liveEval;
  int _liveToken = 0;

  late final ChessboardController _board = ChessboardController(game: _gameData());

  @override
  void initState() {
    super.initState();
    _startAnalysis();
  }

  @override
  void dispose() {
    _analysisSub?.cancel();
    _board.dispose();
    super.dispose();
  }

  Future<void> _startAnalysis() async {
    final cached = await services.analyzer.cached(game);
    if (!mounted) return;
    if (cached != null) {
      setState(() => _analysis = cached);
      return;
    }
    _analysisSub = services.analyzer
        .analyze(game, services.settings.depth)
        .listen(
          (a) => setState(() => _analysis = a),
          onError: (Object e) => setState(
            () => _engineError = e is EngineException ? e.message : 'Stockfish ran into a problem.',
          ),
        );
  }

  // ---- Displayed position ----

  bool get _exploring => _variation.isNotEmpty;

  Position get _position => _exploring ? _variation.last.after : game.positions[_ply];

  Move? get _lastMove => _exploring
      ? _variation.last.move
      : (_ply > 0 ? game.moves[_ply - 1] : null);

  GameData _gameData() {
    final pos = _position;
    return GameData(
      fen: pos.fen,
      lastMove: _lastMove,
      playerSide: pos.isGameOver
          ? PlayerSide.none
          : (pos.turn == Side.white ? PlayerSide.white : PlayerSide.black),
      sideToMove: pos.turn,
      validMoves: makeLegalMoves(pos),
      kingSquareInCheck: pos.isCheck ? pos.board.kingOf(pos.turn) : null,
    );
  }

  void _syncBoard() => _board.updatePosition(_gameData());

  void _go(int ply) {
    setState(() {
      _variation.clear();
      _branchPly = null;
      _liveEval = null;
      _ply = ply.clamp(0, game.plyCount);
    });
    _syncBoard();
  }

  void _back() {
    if (_exploring) {
      setState(() {
        _variation.removeLast();
        if (_variation.isEmpty) _branchPly = null;
      });
      _syncBoard();
      _refreshLiveEval();
    } else {
      _go(_ply - 1);
    }
  }

  void _forward() {
    if (!_exploring) _go(_ply + 1);
  }

  void _onBoardMove(Move move, {bool? viaDragAndDrop}) {
    final pos = _position;
    if (!pos.isLegal(move)) return;
    final (after, san) = pos.makeSan(move);
    if (!_exploring && _ply < game.plyCount && _bare(san) == _bare(game.sans[_ply])) {
      _go(_ply + 1);
      return;
    }
    setState(() {
      _branchPly ??= _ply;
      _variation.add(VariationMove(move, san, after));
    });
    _syncBoard();
    _refreshLiveEval();
  }

  Future<void> _refreshLiveEval() async {
    final token = ++_liveToken;
    setState(() => _liveEval = null);
    if (!_exploring) return;
    final pos = _position;
    if (pos.isCheckmate) {
      setState(
        () => _liveEval = PositionEval(
          eval: Eval.checkmate(whiteWon: pos.turn == Side.black),
          pv: const [],
          depth: 0,
        ),
      );
      return;
    }
    try {
      final lines = await StockfishEngine.instance.analyze(
        pos.fen,
        depth: 18,
        movetime: const Duration(milliseconds: 1200),
        interactive: true,
      );
      if (!mounted || token != _liveToken) return;
      final best = lines.first;
      setState(() => _liveEval = PositionEval(eval: best.eval, pv: best.pv, depth: best.depth));
    } on EngineException catch (e) {
      if (mounted) setState(() => _engineError = e.message);
    }
  }

  static String _bare(String san) => san.replaceAll(RegExp(r'[+#!?]'), '');

  // ---- UI ----

  Eval? get _shownEval => _exploring ? _liveEval?.eval : _analysis?.evalAt(_ply);

  @override
  Widget build(BuildContext context) {
    final analysis = _analysis;
    final top = _orientation == Side.white ? game.black : game.white;
    final bottom = _orientation == Side.white ? game.white : game.black;
    final markers = <int, Color>{};
    final colors = <int, Color>{};
    if (analysis != null) {
      for (var p = 1; p < analysis.evals.length; p++) {
        final c = qualityColor(analysis.qualityOf(p));
        if (c != null) {
          colors[p] = c;
          if (c != kInaccuracy) markers[p] = c;
        }
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${game.white.name} vs ${game.black.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
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
          children: [
            _PlayerLine(player: top),
            LayoutBuilder(
              builder: (context, constraints) {
                const barWidth = 16.0;
                const gap = 6.0;
                final boardSize = constraints.maxWidth - barWidth - gap - 8;
                return Padding(
                  padding: const EdgeInsets.only(left: 4, right: 4),
                  child: Row(
                    children: [
                      EvalBar(eval: _shownEval, orientation: _orientation, height: boardSize),
                      const SizedBox(width: gap),
                      Chessboard(
                        size: boardSize,
                        controller: _board,
                        orientation: _orientation,
                        onMove: _onBoardMove,
                        settings: const ChessboardSettings(
                          enablePremoves: false,
                          animationDuration: Duration(milliseconds: 180),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            _PlayerLine(player: bottom),
            MoveStrip(
              game: game,
              currentPly: _exploring ? (_branchPly ?? _ply) : _ply,
              onSelectPly: _go,
              colors: colors,
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                children: [
                  _MoveInfo(
                    game: game,
                    ply: _ply,
                    analysis: analysis,
                    variation: _variation,
                    branchPly: _branchPly,
                    liveEval: _liveEval,
                    onBackToGame: () => _go(_branchPly ?? _ply),
                  ),
                  const SizedBox(height: 12),
                  if (_engineError != null)
                    Text(_engineError!, style: const TextStyle(color: kLoss))
                  else if (analysis == null || !analysis.isComplete)
                    _AnalysisProgress(done: analysis?.evals.length ?? 0, total: game.positions.length),
                  const SizedBox(height: 8),
                  EvalGraph(
                    evals: [for (final e in analysis?.evals ?? const <PositionEval>[]) e.eval],
                    plyCount: game.plyCount,
                    currentPly: _ply,
                    onSelectPly: _go,
                    markers: markers,
                  ),
                ],
              ),
            ),
            _NavBar(
              canBack: _exploring || _ply > 0,
              canForward: !_exploring && _ply < game.plyCount,
              onStart: () => _go(0),
              onBack: _back,
              onForward: _forward,
              onEnd: () => _go(game.plyCount),
            ),
          ],
        ),
      ),
    );
  }
}

class _MoveInfo extends StatelessWidget {
  const _MoveInfo({
    required this.game,
    required this.ply,
    required this.analysis,
    required this.variation,
    required this.branchPly,
    required this.liveEval,
    required this.onBackToGame,
  });

  final GameRecord game;
  final int ply;
  final GameAnalysis? analysis;
  final List<VariationMove> variation;
  final int? branchPly;
  final PositionEval? liveEval;
  final VoidCallback onBackToGame;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (variation.isNotEmpty) {
      final start = game.positions[branchPly ?? ply];
      final line = variation.map((v) => v.san).join(' ');
      final best = liveEval == null
          ? null
          : uciLineToSan(variation.last.after, liveEval!.pv.take(4).toList()).join(' ');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.alt_route, size: 18, color: kAmber),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Exploring from ${game.moveLabel(branchPly ?? ply)}',
                  style: text.titleSmall?.copyWith(color: kAmber),
                ),
              ),
              TextButton(onPressed: onBackToGame, child: const Text('Back to game')),
            ],
          ),
          Text(
            '${start.turn == Side.white ? '' : '… '}$line',
            style: text.titleMedium?.copyWith(color: kIvory),
          ),
          const SizedBox(height: 4),
          Text(
            liveEval == null
                ? 'Stockfish is thinking…'
                : 'Eval ${liveEval!.eval.label}${best != null && best.isNotEmpty ? '  ·  Best line: $best' : ''}',
            style: text.bodyMedium?.copyWith(color: kIvoryMuted),
          ),
        ],
      );
    }

    final quality = analysis?.qualityOf(ply);
    final eval = analysis?.evalAt(ply);
    final bestBefore = ply > 0 ? analysis?.bestSanAt(ply - 1) : null;
    final showBest =
        quality != null &&
        quality != MoveQuality.best &&
        quality != MoveQuality.good &&
        bestBefore != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(game.moveLabel(ply), style: text.titleLarge?.copyWith(color: kIvory)),
            ),
            if (quality != null && ply > 0)
              _QualityChip(quality: quality),
            if (eval != null) ...[
              const SizedBox(width: 8),
              Text(eval.label, style: text.titleMedium?.copyWith(color: kIvoryMuted)),
            ],
          ],
        ),
        if (showBest)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Best was $bestBefore',
              style: text.bodyMedium?.copyWith(color: kIvoryMuted),
            ),
          ),
        if (ply == game.plyCount)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Result: ${game.result.label}${game.status != null ? ' (${game.status})' : ''}',
              style: text.bodyMedium?.copyWith(color: kIvoryMuted),
            ),
          ),
      ],
    );
  }
}

class _QualityChip extends StatelessWidget {
  const _QualityChip({required this.quality});

  final MoveQuality quality;

  @override
  Widget build(BuildContext context) {
    final color = qualityColor(quality) ?? (quality == MoveQuality.best ? kWin : kIvoryMuted);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        quality.label,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _AnalysisProgress extends StatelessWidget {
  const _AnalysisProgress({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Stockfish is analyzing the game… $done / $total positions',
          style: const TextStyle(color: kIvoryMuted, fontSize: 13),
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(
          value: total == 0 ? null : done / total,
          minHeight: 4,
          borderRadius: BorderRadius.circular(2),
        ),
      ],
    );
  }
}

class _NavBar extends StatelessWidget {
  const _NavBar({
    required this.canBack,
    required this.canForward,
    required this.onStart,
    required this.onBack,
    required this.onForward,
    required this.onEnd,
  });

  final bool canBack;
  final bool canForward;
  final VoidCallback onStart;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            tooltip: 'Start',
            iconSize: 30,
            icon: const Icon(Icons.first_page),
            onPressed: canBack ? onStart : null,
          ),
          IconButton(
            tooltip: 'Previous move',
            iconSize: 38,
            icon: const Icon(Icons.chevron_left),
            onPressed: canBack ? onBack : null,
          ),
          IconButton(
            tooltip: 'Next move',
            iconSize: 38,
            icon: const Icon(Icons.chevron_right),
            onPressed: canForward ? onForward : null,
          ),
          IconButton(
            tooltip: 'End',
            iconSize: 30,
            icon: const Icon(Icons.last_page),
            onPressed: canForward ? onEnd : null,
          ),
        ],
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(player.isAi ? Icons.memory : Icons.person_outline, size: 18, color: kIvoryMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              player.display,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kIvory, fontSize: 15),
            ),
          ),
          if (diff != null)
            Text(
              diff >= 0 ? '+$diff' : '$diff',
              style: TextStyle(color: diff >= 0 ? kWin : kLoss, fontSize: 14),
            ),
        ],
      ),
    );
  }
}
