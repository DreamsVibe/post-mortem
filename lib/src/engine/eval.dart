import 'dart:math' as math;

/// An engine evaluation, always from White's point of view.
class Eval {
  const Eval.cp(int this.cp) : mate = null, _whiteWon = null;
  const Eval.mate(int this.mate) : cp = null, _whiteWon = null;

  /// The game is over by checkmate.
  const Eval.checkmate({required bool whiteWon}) : cp = null, mate = 0, _whiteWon = whiteWon;

  final bool? _whiteWon;

  /// Centipawns, positive = White is better.
  final int? cp;

  /// Moves to mate, positive = White mates, negative = Black mates. 0 = side to move is mated.
  final int? mate;

  bool get isMate => mate != null;

  /// Winning chances in [-1, 1] from White's point of view (Lichess's formula).
  double get whiteWinChance {
    if (mate != null) {
      if (mate! == 0) return (_whiteWon ?? true) ? 1 : -1;
      return mate! > 0 ? 1 : -1;
    }
    final c = cp!.clamp(-1000, 1000);
    return 2 / (1 + math.exp(-0.00368208 * c)) - 1;
  }

  /// "+0.4", "-1.2", "#3", "#-2".
  String get label {
    if (mate == 0) return 'Mate';
    if (mate != null) return '#${mate!}';
    final pawns = cp! / 100;
    final s = pawns.abs() >= 10 ? pawns.toStringAsFixed(0) : pawns.toStringAsFixed(1);
    return pawns > 0 ? '+$s' : s;
  }

  bool get isCheckmate => mate == 0;

  Map<String, dynamic> toJson() => {
    if (cp != null) 'cp': cp,
    if (mate != null) 'mate': mate,
    if (_whiteWon != null) 'whiteWon': _whiteWon,
  };

  static Eval fromJson(Map<String, dynamic> j) {
    if (j['whiteWon'] != null) return Eval.checkmate(whiteWon: j['whiteWon'] as bool);
    if (j['mate'] != null) return Eval.mate((j['mate'] as num).toInt());
    return Eval.cp((j['cp'] as num).toInt());
  }

  @override
  String toString() => label;
}

/// One principal variation from the engine.
class EngineLine {
  const EngineLine({required this.eval, required this.pv, required this.depth});

  final Eval eval;

  /// Moves in UCI notation, starting with the best move.
  final List<String> pv;
  final int depth;
}

/// How good a played move was, judged by the drop in winning chances.
enum MoveQuality {
  best('Best'),
  good('Good'),
  inaccuracy('Inaccuracy'),
  mistake('Mistake'),
  blunder('Blunder');

  const MoveQuality(this.label);
  final String label;

  /// Lichess-style thresholds on the mover's winning-chance loss (scale -1..1).
  static MoveQuality fromLoss(double loss, {required bool wasBest}) {
    if (wasBest) return MoveQuality.best;
    if (loss >= 0.3) return MoveQuality.blunder;
    if (loss >= 0.2) return MoveQuality.mistake;
    if (loss >= 0.1) return MoveQuality.inaccuracy;
    return MoveQuality.good;
  }
}
