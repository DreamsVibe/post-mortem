import 'package:dartchess/dartchess.dart';

/// Turns positions and moves into concrete, verified facts a coach would point at.
///
/// Everything here is computed from the board itself, so it is always correct. The Professor's
/// job is to explain these facts, not to calculate them.
class PositionFacts {
  PositionFacts._();

  static const _values = {
    Role.pawn: 1,
    Role.knight: 3,
    Role.bishop: 3,
    Role.rook: 5,
    Role.queen: 9,
    Role.king: 0,
  };

  static String _roleName(Role r) => switch (r) {
    Role.pawn => 'pawn',
    Role.knight => 'knight',
    Role.bishop => 'bishop',
    Role.rook => 'rook',
    Role.queen => 'queen',
    Role.king => 'king',
  };

  static String _side(Side s) => s == Side.white ? 'White' : 'Black';

  static String _piece(Board b, Square sq) {
    final p = b.pieceAt(sq);
    if (p == null) return sq.name;
    return '${_side(p.color)} ${_roleName(p.role)} on ${sq.name}';
  }

  static String _short(Board b, Square sq) {
    final p = b.pieceAt(sq);
    if (p == null) return sq.name;
    return '${_roleName(p.role)} on ${sq.name}';
  }

  static int material(Board b, Side side) {
    var total = 0;
    for (final sq in b.bySide(side).squares) {
      total += _values[b.roleAt(sq)] ?? 0;
    }
    return total;
  }

  // ---- Attack helpers ----

  static SquareSet _attackers(Board b, Square sq, Side by) =>
      b.attacksTo(sq, by, occupied: b.occupied);

  /// Pieces of [side] that are attacked and not adequately defended: attacked by a cheaper piece,
  /// or attacked more times than defended.
  static List<Square> loosePieces(Board b, Side side) {
    final out = <Square>[];
    for (final sq in b.bySide(side).squares) {
      final role = b.roleAt(sq);
      if (role == null || role == Role.king) continue;
      final attackers = _attackers(b, sq, side.opposite);
      if (attackers.isEmpty) continue;
      final defenders = _attackers(b, sq, side);
      final value = _values[role]!;
      // A king can only capture an undefended piece, so it counts as the most expensive attacker.
      final cheapest = attackers.squares
          .map((a) => b.roleAt(a) == Role.king ? 100 : (_values[b.roleAt(a)] ?? 100))
          .fold<int>(100, (m, v) => v < m ? v : m);
      if (defenders.isEmpty || cheapest < value || attackers.size > defenders.size) {
        out.add(sq);
      }
    }
    return out;
  }

  /// Pieces of [side] pinned against their king (absolute) or queen (relative).
  static List<String> pins(Board b, Side side) {
    final out = <String>[];
    final enemy = side.opposite;
    final targets = [
      if (b.kingOf(side) != null) b.kingOf(side)!,
      ...b.piecesOf(side, Role.queen).squares,
    ];
    for (final target in targets) {
      for (final slider in (b.bySide(enemy) & (b.bishops | b.rooks | b.queens)).squares) {
        final role = b.roleAt(slider)!;
        final df = (slider.file - target.file).abs();
        final dr = (slider.rank - target.rank).abs();
        final diagonal = df == dr && df != 0;
        final straight = (df == 0) != (dr == 0);
        if (!diagonal && !straight) continue;
        if (diagonal && role == Role.rook) continue;
        if (straight && role == Role.bishop) continue;
        final blockers = between(slider, target) & b.occupied;
        if (blockers.size != 1) continue;
        final pinned = blockers.squares.first;
        if (b.sideAt(pinned) != side) continue;
        final pinnedRole = b.roleAt(pinned)!;
        // Against a queen, only a cheaper attacker makes a real pin (a queen "pinning" to a
        // queen just offers a trade), and the pinned piece must be worth less than the queen.
        if (b.roleAt(target) == Role.queen && (role == Role.queen || _values[pinnedRole]! >= 9)) {
          continue;
        }
        out.add(
          '${_piece(b, pinned)} is pinned to its ${_roleName(b.roleAt(target)!)} by the '
          '${_roleName(role)} on ${slider.name}',
        );
      }
    }
    return out;
  }

  /// Enemy pieces that the piece on [sq] attacks, most valuable first.
  static List<Square> _targetsOf(Board b, Square sq) {
    final p = b.pieceAt(sq);
    if (p == null) return const [];
    final hits = attacks(p, sq, b.occupied) & b.bySide(p.color.opposite);
    final list = hits.squares.toList()
      ..sort((x, y) => (_values[b.roleAt(y)] ?? 10).compareTo(_values[b.roleAt(x)] ?? 10));
    return list;
  }

  // ---- Structure ----

  static List<String> _pawnStructure(Board b, Side side) {
    final pawns = b.piecesOf(side, Role.pawn);
    final enemyPawns = b.piecesOf(side.opposite, Role.pawn);
    final isolated = <String>[];
    final doubled = <String>[];
    final passed = <String>[];
    for (final f in File.values) {
      final onFile = pawns & SquareSet.fromFile(f);
      if (onFile.size > 1) doubled.add(f.name);
    }
    for (final sq in pawns.squares) {
      final f = sq.file;
      var neighbors = SquareSet.empty;
      if (f > 0) neighbors = neighbors | SquareSet.fromFile(File(f - 1));
      if (f < 7) neighbors = neighbors | SquareSet.fromFile(File(f + 1));
      if ((pawns & neighbors).isEmpty) isolated.add(sq.name);
      // Passed: no enemy pawn ahead on this or adjacent files.
      final ahead = enemyPawns.squares.where((e) {
        if ((e.file - f).abs() > 1) return false;
        return side == Side.white ? e.rank > sq.rank : e.rank < sq.rank;
      });
      if (ahead.isEmpty) passed.add(sq.name);
    }
    return [
      if (passed.isNotEmpty) 'passed pawn${passed.length > 1 ? 's' : ''} on ${passed.join(', ')}',
      if (isolated.isNotEmpty) 'isolated pawn${isolated.length > 1 ? 's' : ''} on ${isolated.join(', ')}',
      if (doubled.isNotEmpty) 'doubled pawns on the ${doubled.join(', ')}-file',
    ];
  }

  static (List<String>, Map<Side, List<String>>) _files(Board b) {
    final open = <String>[];
    final half = <Side, List<String>>{Side.white: [], Side.black: []};
    for (final f in File.values) {
      final file = SquareSet.fromFile(f);
      final w = (b.piecesOf(Side.white, Role.pawn) & file).isNotEmpty;
      final bl = (b.piecesOf(Side.black, Role.pawn) & file).isNotEmpty;
      if (!w && !bl) {
        open.add(f.name);
      } else if (!w) {
        half[Side.white]!.add(f.name);
      } else if (!bl) {
        half[Side.black]!.add(f.name);
      }
    }
    return (open, half);
  }

  static List<String> _kingSafety(Board b, Side side, {required bool castled}) {
    final k = b.kingOf(side);
    if (k == null) return const [];
    final forward = side == Side.white ? 1 : -1;
    var shield = 0;
    for (var df = -1; df <= 1; df++) {
      final f = k.file + df;
      if (f < 0 || f > 7) continue;
      for (var dr = 1; dr <= 2; dr++) {
        final r = k.rank + dr * forward;
        if (r < 0 || r > 7) continue;
        final sq = Square.fromCoords(File(f), Rank(r));
        final p = b.pieceAt(sq);
        if (p != null && p.color == side && p.role == Role.pawn) shield++;
      }
    }
    final zone = kingAttacks(k).withSquare(k);
    final attackers = <Square>{};
    for (final sq in zone.squares) {
      attackers.addAll(_attackers(b, sq, side.opposite).squares);
    }
    final openNearKing = <String>[];
    for (var df = -1; df <= 1; df++) {
      final f = k.file + df;
      if (f < 0 || f > 7) continue;
      if ((b.piecesOf(side, Role.pawn) & SquareSet.fromFile(File(f))).isEmpty) {
        openNearKing.add(File(f).name);
      }
    }
    return [
      'king on ${k.name}${castled ? ' (castled)' : ''}',
      '$shield pawn${shield == 1 ? '' : 's'} shielding it',
      if (openNearKing.isNotEmpty) 'no own pawn on the ${openNearKing.join(', ')}-file next to the king',
      if (attackers.isNotEmpty)
        '${attackers.length} enemy piece${attackers.length == 1 ? '' : 's'} aimed at the king zone',
    ];
  }

  static List<String> _activity(Board b, Side side, {required bool opening}) {
    final out = <String>[];
    if (b.piecesOf(side, Role.bishop).size >= 2) out.add('has the bishop pair');
    // Knight outposts: rank 4-6 from its side, defended by a pawn, no enemy pawn can chase it.
    for (final n in b.piecesOf(side, Role.knight).squares) {
      final rel = side == Side.white ? n.rank : 7 - n.rank;
      if (rel < 3 || rel > 5) continue;
      final pawnDefended =
          (_attackers(b, n, side) & b.piecesOf(side, Role.pawn)).isNotEmpty;
      final chasers = b.piecesOf(side.opposite, Role.pawn).squares.where((e) {
        if ((e.file - n.file).abs() != 1) return false;
        return side == Side.white ? e.rank > n.rank : e.rank < n.rank;
      });
      if (pawnDefended && chasers.isEmpty) out.add('knight on ${n.name} is on a strong outpost');
    }
    final (open, half) = _files(b);
    for (final r in (b.piecesOf(side, Role.rook) | b.piecesOf(side, Role.queen)).squares) {
      final f = r.file.name;
      if (open.contains(f)) {
        out.add('${_short(b, r)} on the open $f-file');
      } else if (half[side]!.contains(f)) {
        out.add('${_short(b, r)} on the half-open $f-file');
      }
    }
    for (final r in b.piecesOf(side, Role.rook).squares) {
      final rel = side == Side.white ? r.rank : 7 - r.rank;
      if (rel == 6) out.add('rook on the 7th rank (${r.name})');
    }
    if (opening) {
      final back = SquareSet.fromRank(side == Side.white ? Rank.first : Rank.eighth);
      final undeveloped = ((b.piecesOf(side, Role.knight) | b.piecesOf(side, Role.bishop)) & back)
          .squares
          .map((s) => _short(b, s))
          .toList();
      if (undeveloped.isNotEmpty) out.add('undeveloped: ${undeveloped.join(', ')}');
    }
    // Mobility as a rough measure of activity.
    var reach = 0;
    for (final sq in b.bySide(side).diff(b.pawns).diff(b.kings).squares) {
      reach += attacks(b.pieceAt(sq)!, sq, b.occupied).diff(b.bySide(side)).size;
    }
    out.add('pieces reach $reach squares');
    return out;
  }

  // ---- Public descriptions ----

  /// A small text diagram of the board, White at the bottom.
  static String diagram(Position pos) {
    final b = pos.board;
    final lines = <String>[];
    for (var r = 7; r >= 0; r--) {
      final row = StringBuffer('${r + 1} ');
      for (var f = 0; f < 8; f++) {
        final p = b.pieceAt(Square.fromCoords(File(f), Rank(r)));
        if (p == null) {
          row.write('. ');
        } else {
          final l = switch (p.role) {
            Role.pawn => 'p',
            Role.knight => 'n',
            Role.bishop => 'b',
            Role.rook => 'r',
            Role.queen => 'q',
            Role.king => 'k',
          };
          row.write('${p.color == Side.white ? l.toUpperCase() : l} ');
        }
      }
      lines.add(row.toString().trimRight());
    }
    lines.add('  a b c d e f g h   (uppercase = White)');
    return lines.join('\n');
  }

  /// Full picture of a position: material, loose pieces, pins, kings, structure, activity.
  static String position(Position pos, {required Set<Side> castled, required bool opening}) {
    final b = pos.board;
    final out = StringBuffer();
    final wm = material(b, Side.white);
    final bm = material(b, Side.black);
    final diff = wm - bm;
    out.writeln(
      '- Material: White $wm, Black $bm'
      '${diff == 0 ? ' (level)' : ' (${diff > 0 ? 'White' : 'Black'} up ${diff.abs()})'}.',
    );
    if (pos.isCheck) out.writeln('- ${_side(pos.turn)} is in check.');
    for (final side in Side.values) {
      final loose = loosePieces(b, side);
      if (loose.isNotEmpty) {
        out.writeln('- ${_side(side)} loose pieces (attacked, not safely defended): '
            '${loose.map((s) => _short(b, s)).join(', ')}.');
      }
      for (final p in pins(b, side)) {
        out.writeln('- $p.');
      }
    }
    for (final side in Side.values) {
      out.writeln('- ${_side(side)} king: ${_kingSafety(b, side, castled: castled.contains(side)).join('; ')}.');
    }
    for (final side in Side.values) {
      final s = _pawnStructure(b, side);
      if (s.isNotEmpty) out.writeln('- ${_side(side)} pawns: ${s.join('; ')}.');
    }
    final (open, _) = _files(b);
    if (open.isNotEmpty) out.writeln('- Open files: ${open.join(', ')}.');
    for (final side in Side.values) {
      out.writeln('- ${_side(side)} activity: ${_activity(b, side, opening: opening).join('; ')}.');
    }
    return out.toString().trimRight();
  }

  /// What a move concretely changed on the board.
  static String move(Position before, Move move, Position after) {
    final mover = before.turn;
    final enemy = mover.opposite;
    final b0 = before.board;
    final b1 = after.board;
    final facts = <String>[];

    if (move is NormalMove) {
      final captured = b0.pieceAt(move.to) ??
          (b0.roleAt(move.from) == Role.pawn && move.from.file != move.to.file
              ? Piece(color: enemy, role: Role.pawn)
              : null);
      if (captured != null && captured.color == enemy) {
        facts.add('captures a ${_roleName(captured.role)}');
      }
      final landed = b1.pieceAt(move.to) != null ? move.to : null;
      if (landed != null && b1.roleAt(landed) != Role.king) {
        final targets = _targetsOf(b1, landed)
            .where((t) => b1.roleAt(t) != Role.pawn || _attackers(b1, t, enemy).isEmpty)
            .toList();
        if (targets.length >= 2 &&
            targets.where((t) => (_values[b1.roleAt(t)] ?? 10) >= 3 || b1.roleAt(t) == Role.king).length >= 2) {
          facts.add('forks ${targets.take(3).map((t) => _short(b1, t)).join(' and ')}');
        } else if (targets.isNotEmpty) {
          facts.add('now attacks ${targets.take(3).map((t) => _short(b1, t)).join(', ')}');
        }
        if (_attackers(b1, landed, enemy).isNotEmpty && _attackers(b1, landed, mover).isEmpty) {
          facts.add('the moved piece stands undefended where it can be taken');
        }
      }
    }
    if (after.isCheck) facts.add('gives check');

    // Pieces of the mover that became loose, or stopped being loose.
    final looseBefore = loosePieces(b0, mover).map((s) => s.name).toSet();
    final looseAfter = loosePieces(b1, mover);
    final newlyLoose = looseAfter.where((s) => !looseBefore.contains(s.name) && s != move.to).toList();
    if (newlyLoose.isNotEmpty) {
      facts.add('leaves ${newlyLoose.map((s) => _short(b1, s)).join(', ')} under-defended');
    }
    final enemyLooseBefore = loosePieces(b0, enemy).map((s) => s.name).toSet();
    final enemyLooseAfter = loosePieces(b1, enemy).map((s) => s.name).toSet();
    final saved = enemyLooseBefore.difference(enemyLooseAfter);
    if (saved.isNotEmpty && facts.every((f) => !f.startsWith('captures'))) {
      facts.add('no longer attacks the ${saved.join(', ')} square${saved.length > 1 ? 's' : ''}');
    }

    // New pins against the enemy.
    final pinsBefore = pins(b0, enemy).toSet();
    for (final p in pins(b1, enemy)) {
      if (!pinsBefore.contains(p)) facts.add('creates a pin: $p');
    }

    // Files and structure.
    final (open0, _) = _files(b0);
    final (open1, _) = _files(b1);
    final opened = open1.where((f) => !open0.contains(f)).toList();
    if (opened.isNotEmpty) facts.add('opens the ${opened.join(', ')}-file');
    final s0 = _pawnStructure(b0, mover).toSet();
    for (final s in _pawnStructure(b1, mover)) {
      if (!s0.contains(s)) facts.add('own pawns now: $s');
    }
    final e0 = _pawnStructure(b0, enemy).toSet();
    for (final s in _pawnStructure(b1, enemy)) {
      if (!e0.contains(s)) facts.add('opponent pawns now: $s');
    }
    if (b0.piecesOf(mover, Role.bishop).size >= 2 && b1.piecesOf(mover, Role.bishop).size < 2) {
      facts.add('gives up the bishop pair');
    }
    if (b0.piecesOf(enemy, Role.bishop).size >= 2 && b1.piecesOf(enemy, Role.bishop).size < 2) {
      facts.add('takes away the opponent\'s bishop pair');
    }
    final backRank = SquareSet.fromRank(mover == Side.white ? Rank.first : Rank.eighth);
    final rightsBefore = (before.castles.castlingRights & backRank).size;
    final rightsAfter = (after.castles.castlingRights & backRank).size;
    final castledNow = move is NormalMove &&
        b0.roleAt(move.from) == Role.king &&
        ((move.to.file - move.from.file).abs() >= 2 || b0.sideAt(move.to) == mover);
    if (castledNow) {
      facts.add('castles');
    } else if (rightsAfter < rightsBefore) {
      facts.add(rightsAfter == 0 ? 'gives up the right to castle' : 'loses a castling option');
    }
    return facts.isEmpty ? 'quiet move' : facts.join('; ');
  }

  /// Plays an engine line and reports what it concretely achieves.
  static String line(Position start, List<String> uci, {int maxPlies = 8}) {
    final sans = <String>[];
    final events = <String>[];
    var pos = start;
    final side = start.turn;
    final m0 = material(start.board, side) - material(start.board, side.opposite);
    for (final u in uci.take(maxPlies)) {
      final mv = Move.parse(u);
      if (mv == null || !pos.isLegal(mv)) break;
      final (next, san) = pos.makeSan(mv);
      final fact = move(pos, mv, next);
      if (fact.contains('forks') || fact.contains('creates a pin')) {
        events.add('$san ${fact.split('; ').firstWhere((f) => f.contains('forks') || f.contains('pin'))}');
      }
      sans.add(san);
      pos = next;
      if (pos.isCheckmate) {
        events.add('ends in checkmate');
        break;
      }
    }
    if (sans.isEmpty) return '';
    final m1 = material(pos.board, side) - material(pos.board, side.opposite);
    final swing = m1 - m0;
    final result = swing == 0
        ? 'material stays level'
        : '${_side(side)} ${swing > 0 ? 'wins' : 'loses'} ${_materialWords(swing.abs())}';
    return '${sans.join(' ')} -> $result${events.isEmpty ? '' : ' (${events.join('; ')})'}';
  }

  static String _materialWords(int n) => switch (n) {
    1 => 'a pawn',
    2 => 'two pawns',
    3 => 'a minor piece (3)',
    4 => 'a minor piece and a pawn (4)',
    5 => 'a rook\'s worth (5)',
    9 => 'a queen\'s worth (9)',
    _ => '$n points of material',
  };
}
