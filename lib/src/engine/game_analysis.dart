import 'dart:async';

import 'package:dartchess/dartchess.dart';

import '../game_record.dart';
import '../storage.dart';
import 'eval.dart';
import 'stockfish_engine.dart';

/// How hard Stockfish thinks about each position.
enum EngineDepth {
  fast('Fast', 12, Duration(milliseconds: 400)),
  medium('Medium', 16, Duration(milliseconds: 1000)),
  deep('Deep', 20, Duration(milliseconds: 2500));

  const EngineDepth(this.label, this.depth, this.movetime);
  final String label;
  final int depth;
  final Duration movetime;

  static EngineDepth byName(String? name) =>
      EngineDepth.values.firstWhere((d) => d.name == name, orElse: () => EngineDepth.medium);
}

/// Stockfish's verdict on one position of the game.
class PositionEval {
  const PositionEval({required this.eval, required this.pv, required this.depth});

  final Eval eval;

  /// Best line from this position, in UCI.
  final List<String> pv;
  final int depth;

  String? get bestUci => pv.isEmpty ? null : pv.first;

  Map<String, dynamic> toJson() => {'eval': eval.toJson(), 'pv': pv, 'depth': depth};

  static PositionEval fromJson(Map<String, dynamic> j) => PositionEval(
    eval: Eval.fromJson((j['eval'] as Map).cast<String, dynamic>()),
    pv: (j['pv'] as List).cast<String>(),
    depth: (j['depth'] as num).toInt(),
  );
}

/// Engine analysis of a whole game: one [PositionEval] per position (plies + 1).
class GameAnalysis {
  GameAnalysis(this.game, this.evals, this.depthSetting);

  final GameRecord game;
  final List<PositionEval> evals;
  final EngineDepth depthSetting;

  bool get isComplete => evals.length == game.positions.length;

  /// Eval of positions[ply], if analyzed.
  Eval? evalAt(int ply) => ply < evals.length ? evals[ply].eval : null;

  /// Quality of the move that led to positions[ply] (ply ≥ 1).
  MoveQuality? qualityOf(int ply) {
    if (ply < 1 || ply >= evals.length) return null;
    final before = evals[ply - 1];
    final after = evals[ply];
    final mover = game.positions[ply - 1].turn;
    final sign = mover == Side.white ? 1 : -1;
    final loss = (before.eval.whiteWinChance - after.eval.whiteWinChance) * sign;
    // Compare in SAN: castling is king-to-rook in dartchess but king-two-squares in UCI output.
    final bestSan = bestSanAt(ply - 1);
    final wasBest = bestSan != null && _bare(bestSan) == _bare(game.sans[ply - 1]);
    return MoveQuality.fromLoss(loss, wasBest: wasBest);
  }

  static String _bare(String san) => san.replaceAll(RegExp(r'[+#!?]'), '');

  /// Winning-chance loss (0..2) for the mover of the move that led to positions[ply].
  double lossOf(int ply) {
    if (ply < 1 || ply >= evals.length) return 0;
    final mover = game.positions[ply - 1].turn;
    final sign = mover == Side.white ? 1 : -1;
    return ((evals[ply - 1].eval.whiteWinChance - evals[ply].eval.whiteWinChance) * sign)
        .clamp(0, 2)
        .toDouble();
  }

  /// SAN of the engine's best move in positions[ply], if known.
  String? bestSanAt(int ply) {
    if (ply >= evals.length) return null;
    return uciLineToSan(game.positions[ply], evals[ply].pv.take(1).toList()).firstOrNull;
  }

  /// The best line from positions[ply] in SAN, up to [max] moves.
  List<String> bestLineSan(int ply, {int max = 5}) {
    if (ply >= evals.length) return const [];
    return uciLineToSan(game.positions[ply], evals[ply].pv.take(max).toList());
  }

  Map<String, dynamic> toJson() => {
    'depth': depthSetting.name,
    'evals': [for (final e in evals) e.toJson()],
  };
}

/// Converts a line of UCI moves to SAN, stopping at the first move that doesn't parse.
List<String> uciLineToSan(Position start, List<String> uci) {
  final out = <String>[];
  var pos = start;
  for (final u in uci) {
    final move = Move.parse(u);
    if (move == null || !pos.isLegal(move)) break;
    final (next, san) = pos.makeSan(move);
    out.add(san);
    pos = next;
  }
  return out;
}

/// Runs Stockfish over every position of a game, reporting progress as it goes and caching the
/// finished result, so each game is only analyzed once per depth setting.
class GameAnalyzer {
  GameAnalyzer(this.store, {StockfishEngine? engine})
    : engine = engine ?? StockfishEngine.instance;

  final LocalStore store;
  final StockfishEngine engine;

  Future<GameAnalysis?> cached(GameRecord game) async {
    final json = await store.read('evals', gameKey(game));
    if (json == null) return null;
    try {
      final evals = [
        for (final e in json['evals'] as List) PositionEval.fromJson((e as Map).cast()),
      ];
      if (evals.length != game.positions.length) return null;
      return GameAnalysis(game, evals, EngineDepth.byName(json['depth'] as String?));
    } catch (_) {
      return null;
    }
  }

  /// Streams the growing analysis; the last event is complete and has been cached.
  Stream<GameAnalysis> analyze(GameRecord game, EngineDepth depth) async* {
    final evals = <PositionEval>[];
    for (final pos in game.positions) {
      final PositionEval pe;
      if (pos.isCheckmate) {
        pe = PositionEval(
          eval: Eval.checkmate(whiteWon: pos.turn == Side.black),
          pv: const [],
          depth: 0,
        );
      } else if (pos.isStalemate || pos.isInsufficientMaterial) {
        pe = const PositionEval(eval: Eval.cp(0), pv: [], depth: 0);
      } else {
        final lines = await engine.analyze(
          pos.fen,
          depth: depth.depth,
          movetime: depth.movetime,
        );
        final best = lines.first;
        pe = PositionEval(eval: best.eval, pv: best.pv.take(8).toList(), depth: best.depth);
      }
      evals.add(pe);
      yield GameAnalysis(game, List.of(evals), depth);
    }
    final done = GameAnalysis(game, evals, depth);
    await store.write('evals', gameKey(game), done.toJson());
  }
}
