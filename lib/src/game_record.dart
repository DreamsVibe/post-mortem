import 'package:dartchess/dartchess.dart';

/// How a game ended, from White's point of view.
enum GameResult {
  whiteWins('1-0'),
  blackWins('0-1'),
  draw('½-½'),
  unknown('*');

  const GameResult(this.label);
  final String label;
}

/// One player's side of a game.
class GamePlayer {
  const GamePlayer({required this.name, this.rating, this.ratingDiff, this.isAi = false});

  final String name;
  final int? rating;
  final int? ratingDiff;
  final bool isAi;

  String get display => rating == null ? name : '$name ($rating)';
}

/// A complete game, parsed and replayed so every position is ready to show.
///
/// [positions] has one more entry than [moves]: positions[0] is the start,
/// positions[i] is the position after moves[i - 1].
class GameRecord {
  GameRecord._({
    required this.id,
    required this.white,
    required this.black,
    required this.result,
    required this.speed,
    required this.status,
    required this.openingName,
    required this.playedAt,
    required this.sans,
    required this.moves,
    required this.positions,
  });

  /// Lichess game ID, or null for a pasted PGN.
  final String? id;
  final GamePlayer white;
  final GamePlayer black;
  final GameResult result;

  /// bullet / blitz / rapid / classical / correspondence, when known.
  final String? speed;
  final String? status;
  final String? openingName;
  final DateTime? playedAt;
  final List<String> sans;
  final List<Move> moves;
  final List<Position> positions;

  int get plyCount => moves.length;

  /// Builds a record from a Lichess game JSON object (API export format).
  /// Returns null for variants Post Mortem does not handle yet.
  static GameRecord? fromLichessJson(Map<String, dynamic> json) {
    final variant = json['variant'] as String? ?? 'standard';
    if (variant != 'standard') return null;

    final players = (json['players'] as Map?)?.cast<String, dynamic>() ?? const {};
    GamePlayer parsePlayer(dynamic raw, String fallback) {
      final p = (raw as Map?)?.cast<String, dynamic>() ?? const {};
      final user = (p['user'] as Map?)?.cast<String, dynamic>();
      final aiLevel = p['aiLevel'];
      final name = user?['name'] as String? ??
          (aiLevel != null ? 'Stockfish level $aiLevel' : fallback);
      return GamePlayer(
        name: name,
        rating: (p['rating'] as num?)?.toInt(),
        ratingDiff: (p['ratingDiff'] as num?)?.toInt(),
        isAi: aiLevel != null,
      );
    }

    final winner = json['winner'] as String?;
    final status = json['status'] as String?;
    final result = switch (winner) {
      'white' => GameResult.whiteWins,
      'black' => GameResult.blackWins,
      _ => (status == null || status == 'started' || status == 'created')
          ? GameResult.unknown
          : GameResult.draw,
    };

    final createdAt = (json['createdAt'] as num?)?.toInt();
    final movesStr = (json['moves'] as String? ?? '').trim();
    final sans = movesStr.isEmpty ? <String>[] : movesStr.split(RegExp(r'\s+'));
    final opening = (json['opening'] as Map?)?.cast<String, dynamic>();

    return _replay(
      id: json['id'] as String?,
      white: parsePlayer(players['white'], 'White'),
      black: parsePlayer(players['black'], 'Black'),
      result: result,
      speed: json['speed'] as String?,
      status: status,
      openingName: opening?['name'] as String?,
      playedAt: createdAt == null ? null : DateTime.fromMillisecondsSinceEpoch(createdAt),
      start: Chess.initial,
      sans: sans,
    );
  }

  /// Builds a record from pasted PGN text. Throws [FormatException] when the
  /// text has no playable moves or is a variant Post Mortem does not handle.
  static GameRecord fromPgn(String pgn) {
    final game = PgnGame.parsePgn(pgn);
    final headers = game.headers;
    final variant = headers['Variant'];
    if (variant != null && variant.toLowerCase() != 'standard') {
      throw const FormatException('Only standard chess games are supported for now.');
    }
    final Position start;
    try {
      start = PgnGame.startingPosition(headers);
    } catch (_) {
      throw const FormatException('The PGN has a starting position that could not be read.');
    }
    final sans = game.moves.mainline().map((n) => n.san).toList();
    if (sans.isEmpty) {
      throw const FormatException('No moves found in that PGN.');
    }

    int? elo(String? v) => v == null ? null : int.tryParse(v);
    final result = switch (headers['Result']) {
      '1-0' => GameResult.whiteWins,
      '0-1' => GameResult.blackWins,
      '1/2-1/2' => GameResult.draw,
      _ => GameResult.unknown,
    };

    final site = headers['Site'] ?? '';
    final idMatch = RegExp(r'lichess\.org/([A-Za-z0-9]{8})').firstMatch(site);

    return _replay(
      id: idMatch?.group(1),
      white: GamePlayer(name: headers['White'] ?? 'White', rating: elo(headers['WhiteElo'])),
      black: GamePlayer(name: headers['Black'] ?? 'Black', rating: elo(headers['BlackElo'])),
      result: result,
      speed: _speedFromTimeControl(headers['TimeControl']),
      status: headers['Termination'],
      openingName: headers['Opening'],
      playedAt: _parsePgnDate(headers['UTCDate'] ?? headers['Date']),
      start: start,
      sans: sans,
    );
  }

  static GameRecord _replay({
    required String? id,
    required GamePlayer white,
    required GamePlayer black,
    required GameResult result,
    required String? speed,
    required String? status,
    required String? openingName,
    required DateTime? playedAt,
    required Position start,
    required List<String> sans,
  }) {
    final positions = <Position>[start];
    final moves = <Move>[];
    final played = <String>[];
    var pos = start;
    for (final san in sans) {
      final move = pos.parseSan(san);
      if (move == null) break;
      pos = pos.play(move);
      moves.add(move);
      played.add(san);
      positions.add(pos);
    }
    return GameRecord._(
      id: id,
      white: white,
      black: black,
      result: result,
      speed: speed,
      status: status,
      openingName: openingName,
      playedAt: playedAt,
      sans: played,
      moves: moves,
      positions: positions,
    );
  }

  /// Which side [username] played, or null if they didn't play in this game.
  Side? sideOf(String? username) {
    if (username == null) return null;
    final u = username.toLowerCase();
    if (white.name.toLowerCase() == u) return Side.white;
    if (black.name.toLowerCase() == u) return Side.black;
    return null;
  }

  GamePlayer opponentOf(Side side) => side == Side.white ? black : white;

  /// 'Won', 'Lost' or 'Draw' for [side], or null when the result is unknown.
  String? outcomeFor(Side side) {
    switch (result) {
      case GameResult.whiteWins:
        return side == Side.white ? 'Won' : 'Lost';
      case GameResult.blackWins:
        return side == Side.black ? 'Won' : 'Lost';
      case GameResult.draw:
        return 'Draw';
      case GameResult.unknown:
        return null;
    }
  }

  /// Move label for the move that led to positions[ply], e.g. "12. Nf3" or "12… Nc6".
  String moveLabel(int ply) {
    if (ply <= 0 || ply > sans.length) return 'Start';
    final startPly = _startPly;
    final absolute = startPly + ply - 1;
    final number = absolute ~/ 2 + 1;
    final isWhite = absolute.isEven;
    return isWhite ? '$number. ${sans[ply - 1]}' : '$number… ${sans[ply - 1]}';
  }

  int get _startPly {
    final start = positions.first;
    return (start.fullmoves - 1) * 2 + (start.turn == Side.white ? 0 : 1);
  }

  static String? _speedFromTimeControl(String? tc) {
    if (tc == null || tc == '-') return tc == '-' ? 'correspondence' : null;
    final parts = tc.split('+');
    final base = int.tryParse(parts[0]);
    final inc = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    if (base == null) return null;
    final estimate = base + 40 * inc;
    if (estimate < 180) return 'bullet';
    if (estimate < 480) return 'blitz';
    if (estimate < 1500) return 'rapid';
    return 'classical';
  }

  static DateTime? _parsePgnDate(String? d) {
    if (d == null) return null;
    final m = RegExp(r'^(\d{4})\.(\d{2})\.(\d{2})').firstMatch(d);
    if (m == null) return null;
    return DateTime.tryParse('${m.group(1)}-${m.group(2)}-${m.group(3)}');
  }
}
