import 'dart:async';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';

import '../engine/eval.dart';
import '../engine/game_analysis.dart';
import '../engine/position_facts.dart';
import '../game_record.dart';
import '../lichess_client.dart';
import '../settings.dart';
import '../storage.dart';
import 'claude_client.dart';
import 'coach_models.dart';
import 'usage.dart';

/// The Professor's personality and rules, shared by the narration and the chat.
const kProfessorPersona = '''
You are "the Professor", a patient, thorough chess coach inside Post Mortem, an app for reviewing
Lichess games. You explain chess the way a strong human coach does: by pointing at the board.
Talk about pieces, squares, files, pawn structure, king safety, threats and plans, and what each
side is trying to do. You cover every layer of the game where it matters:
- Tactics: forks, pins, skewers, discovered attacks, deflections, overloaded or loose pieces,
  missed or allowed combinations.
- Strategy: plans, piece coordination, initiative, which side of the board to play on.
- Positional theory: pawn structure, weak squares and outposts, open files, good vs bad bishops,
  space, king safety, development.
- Opening theory: the opening and variation, where the game left known theory, the ideas behind it.
- Endgame theory: technique (opposition, Lucena, Philidor, rook activity, passed pawns), with
  tablebase verdicts when 7 or fewer pieces remain.

HOW TO USE THE DATA
- You are given verified BOARD FACTS computed from the actual position (material, loose pieces,
  pins, forks, king safety, pawn structure, open files, outposts, what each move changed) and
  engine lines with what they concretely achieve. Build your explanations from these facts. They
  are correct; do not contradict them, and do not invent board details that aren't supported.
- Stockfish evaluations are only for YOU to judge which moves matter and which side is better.
  Never use the evaluation as the explanation. Do not write numbers like "+0.4" or "-1.2", and
  never say "the engine says", "the evaluation", "the eval", "the number", "Stockfish prefers"
  or "according to the engine". Say what happens on the board instead: which piece becomes weak,
  what the threat is, what line wins material, why the plan works.
- When a better move existed, name it and explain in chess terms why it was better, using the
  facts about its line (for example "Nd2 keeps the e4 pawn defended and stops ...Qb6").
- Use standard algebraic notation exactly as it appears in the data. Never invent moves or
  statistics.
- Pitch explanations to the players' ratings: simpler, concrete ideas for lower-rated players,
  deeper positional ideas for stronger ones.''';

/// Where a review is in its lifecycle, for the progress UI.
enum ReviewStage { preparing, openings, endgames, writing, checking, done }

/// Builds, checks and caches the Professor's review of a game.
class CoachService {
  CoachService({
    required this.claude,
    required this.lichess,
    required this.store,
    required this.settings,
    required this.usage,
  });

  final ClaudeClient claude;
  final LichessClient lichess;
  final LocalStore store;
  final AppSettings settings;
  final UsageTracker usage;

  static const _chunkPlies = 60;

  Future<CoachReview?> cached(GameRecord game) async {
    final j = await store.read('coach', gameKey(game));
    if (j == null) return null;
    try {
      return CoachReview.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteReview(GameRecord game) => store.delete('coach', gameKey(game));

  /// Why the coach can't run right now, or null if it can.
  String? get blockedReason {
    if (!settings.hasApiKey) return 'Add your Anthropic API key in Settings to use the coach.';
    return usage.capReached;
  }

  /// Runs the full review. [analysis] must be complete.
  Future<CoachReview> review(
    GameRecord game,
    GameAnalysis analysis, {
    void Function(ReviewStage stage)? onStage,
  }) async {
    final blocked = blockedReason;
    if (blocked != null) throw ClaudeException(blocked);
    if (!analysis.isComplete) {
      throw const ClaudeException('Wait for Stockfish to finish analyzing the game first.');
    }

    onStage?.call(ReviewStage.preparing);
    final side = game.sideOf(settings.username);
    onStage?.call(ReviewStage.openings);
    final openings = await _openingData(game);
    onStage?.call(ReviewStage.endgames);
    final endgames = await _tablebaseData(game);

    final gameData = buildGameData(game, analysis, perspective: side, openings: openings, endgames: endgames);
    final system = [
      {'type': 'text', 'text': '$kProfessorPersona\n\n$_reviewInstructions'},
      {
        'type': 'text',
        'text': gameData,
        'cache_control': {'type': 'ephemeral'},
      },
    ];

    onStage?.call(ReviewStage.writing);
    var total = const TokenUsage();
    final comments = <int, MoveComment>{};
    String summary = '';
    String? openingName;
    int? leftTheory;
    String? openingIdeas;
    final keyMoments = <int>{};
    String recap = '';
    final lessons = <Lesson>[];

    final n = game.plyCount;
    final chunks = <(int, int)>[];
    final chunkCount = (n / _chunkPlies).ceil().clamp(1, 10);
    final size = (n / chunkCount).ceil();
    for (var start = 1; start <= n; start += size) {
      chunks.add((start, math.min(n, start + size - 1)));
    }

    // The parts are independent (every part sees the whole game), so they run side by side.
    Future<ClaudeResponse> requestPart(int c) {
      final (from, to) = chunks[c];
      final first = c == 0;
      final last = c == chunks.length - 1;
      final single = chunks.length == 1;
      final ask = StringBuffer()
        ..writeln('Write the review for plies $from to $to of this game by calling submit_review.')
        ..writeln('Give every ply from $from to $to exactly one entry in "moves".');
      if (!single) {
        ask.writeln(
          'The review is written in ${chunks.length} parts at the same time; this is part '
          '${c + 1}. Other parts cover the other plies.',
        );
      }
      if (first) {
        ask.writeln('Include "summary", "opening" and "key_moments" (for the whole game).');
      } else {
        ask.writeln('Leave "summary" and "opening" empty. Add any key moments inside your range.');
      }
      if (last) {
        ask.writeln('Include "recap" with 2-4 lessons, covering the whole game.');
      } else {
        ask.writeln('Leave "recap" empty; another part covers the end of the game.');
      }
      return claude.send(
        system: system,
        messages: [
          {'role': 'user', 'content': ask.toString()},
        ],
        tools: [_submitReviewTool],
        toolChoice: {'type': 'tool', 'name': 'submit_review'},
        maxTokens: 20000,
        timeout: const Duration(minutes: 9),
      );
    }

    // Start each later part a few seconds after the first, so it can read the game data from the
    // prompt cache instead of paying full price for it again.
    final responses = await Future.wait([
      for (var c = 0; c < chunks.length; c++)
        Future<void>.delayed(Duration(seconds: c == 0 ? 0 : 6)).then((_) => requestPart(c)),
    ]);
    for (var c = 0; c < chunks.length; c++) {
      final (from, to) = chunks[c];
      final first = c == 0;
      final last = c == chunks.length - 1;
      final res = responses[c];
      total += res.usage;
      final input = res.toolUses.firstOrNull?['input'];
      if (input is! Map) {
        throw const ClaudeException('The Professor sent back a review that could not be read. Try again.');
      }
      final j = input.cast<String, dynamic>();
      if (first) {
        summary = (j['summary'] as String? ?? '').trim();
        final opening = (j['opening'] as Map?)?.cast<String, dynamic>();
        openingName = (opening?['name'] as String?)?.trim();
        leftTheory = (opening?['left_theory_at_ply'] as num?)?.toInt();
        openingIdeas = (opening?['ideas'] as String?)?.trim();
      }
      for (final k in (j['key_moments'] as List? ?? const [])) {
        if (k is num && k >= 1 && k <= n) keyMoments.add(k.toInt());
      }
      if (last) {
        final r = (j['recap'] as Map?)?.cast<String, dynamic>();
        recap = (r?['text'] as String? ?? '').trim();
        for (final l in (r?['lessons'] as List? ?? const [])) {
          if (l is Map && (l['lesson'] as String?)?.trim().isNotEmpty == true) {
            lessons.add(Lesson(l['area'] as String? ?? 'general', (l['lesson'] as String).trim()));
          }
        }
      }
      for (final raw in (j['moves'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final m = parseMoveComment(raw.cast());
        if (m != null && m.ply >= from && m.ply <= to) comments[m.ply] = m;
      }
    }

    // Check every comment against the real game; ask once more for anything missing or wrong.
    onStage?.call(ReviewStage.checking);
    final problems = <int, String>{};
    for (var ply = 1; ply <= n; ply++) {
      final m = comments[ply];
      if (m == null) {
        problems[ply] = 'missing';
        continue;
      }
      final checked = validateComment(game, analysis, m);
      if (checked.$2 != null) {
        problems[ply] = checked.$2!;
      } else {
        comments[ply] = checked.$1;
      }
    }
    if (problems.isNotEmpty) {
      final list = problems.entries.take(120).map((e) => 'ply ${e.key}: ${e.value}').join('\n');
      try {
        final res = await claude.send(
          system: system,
          messages: [
            {
              'role': 'user',
              'content':
                  'Some move comments were missing or referred to moves that are not legal in '
                  'the game at that point. Write fresh entries for only these plies by calling '
                  'submit_review (leave the other fields empty). Only mention moves that appear '
                  'in the game or in the engine lines given for that ply.\n$list',
            },
          ],
          tools: [_submitReviewTool],
          toolChoice: {'type': 'tool', 'name': 'submit_review'},
          maxTokens: 16000,
          timeout: const Duration(minutes: 9),
        );
        total += res.usage;
        final input = res.toolUses.firstOrNull?['input'];
        if (input is Map) {
          for (final raw in (input['moves'] as List? ?? const [])) {
            if (raw is! Map) continue;
            final m = parseMoveComment(raw.cast());
            if (m == null || !problems.containsKey(m.ply)) continue;
            final checked = validateComment(game, analysis, m);
            if (checked.$2 == null) {
              comments[m.ply] = checked.$1;
              problems.remove(m.ply);
            }
          }
        }
      } on ClaudeException {
        // Keep what we have; the remaining problem comments are dropped below.
      }
      for (final ply in problems.keys) {
        comments.remove(ply);
      }
    }

    final cost = total.costFor(settings.model);
    final opponent = side == null ? '${game.white.name} vs ${game.black.name}' : 'vs ${game.opponentOf(side).name}';
    await usage.record(kind: 'Review', label: opponent, cost: cost);

    final review = CoachReview(
      summary: summary,
      openingName: openingName?.isEmpty == true ? null : openingName,
      leftTheoryAtPly: leftTheory,
      openingIdeas: openingIdeas?.isEmpty == true ? null : openingIdeas,
      keyMoments: (keyMoments.toList()..sort()).take(8).toList(),
      moves: comments,
      recapText: recap,
      lessons: lessons.take(4).toList(),
      model: settings.model.label,
      createdAt: DateTime.now(),
      cost: cost,
    );
    await store.write('coach', gameKey(game), review.toJson());
    onStage?.call(ReviewStage.done);
    return review;
  }

  // ---- Pre-fetched Lichess data ----

  /// Master-game statistics along the opening, until the game leaves known theory.
  Future<String> _openingData(GameRecord game) async {
    final out = StringBuffer();
    final limit = math.min(game.plyCount, 30);
    var requests = 0;
    for (var ply = 0; ply < limit && requests < 18; ply++) {
      final pos = game.positions[ply];
      final data = await lichess.openingExplorer(pos.fen, source: 'masters', moves: 4);
      requests++;
      if (data == null) {
        if (ply == 0) return 'Opening explorer: unavailable right now.';
        break;
      }
      final moves = (data['moves'] as List? ?? const []).cast<Map>();
      final total = (data['white'] as num? ?? 0) + (data['draws'] as num? ?? 0) + (data['black'] as num? ?? 0);
      final played = _bare(game.sans[ply]);
      final inBook = moves.any((m) => _bare(m['san'] as String? ?? '') == played);
      final top = moves.take(3).map((m) {
        final games = (m['white'] as num? ?? 0) + (m['draws'] as num? ?? 0) + (m['black'] as num? ?? 0);
        return '${m['san']} ($games games)';
      }).join(', ');
      final name = (data['opening'] as Map?)?['name'];
      out.writeln(
        'ply ${ply + 1} (${game.moveLabel(ply + 1)}): masters played this position $total times; '
        'top moves: ${top.isEmpty ? 'none' : top}${name != null ? '; opening: $name' : ''}'
        '${inBook ? '' : '  <- the game left master theory here'}',
      );
      if (!inBook) break;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return out.isEmpty ? 'Opening explorer: no data.' : out.toString();
  }

  /// Tablebase verdicts for a few positions with 7 or fewer pieces.
  Future<String> _tablebaseData(GameRecord game) async {
    final plies = <int>[];
    for (var ply = 0; ply < game.positions.length; ply++) {
      if (game.positions[ply].board.occupied.size <= 7) plies.add(ply);
    }
    if (plies.isEmpty) return 'Tablebase: the game never reached 7 or fewer pieces.';
    final chosen = <int>{plies.first, plies.last};
    for (var i = 0; i < plies.length; i += 8) {
      chosen.add(plies[i]);
    }
    final out = StringBuffer();
    for (final ply in (chosen.toList()..sort()).take(6)) {
      final pos = game.positions[ply];
      final data = await lichess.tablebase(pos.fen);
      if (data == null) continue;
      final best = (data['moves'] as List? ?? const []).cast<Map>().take(3).map((m) {
        return '${m['san']} (${_tbCategoryAfter(m['category'] as String?)} for the mover)';
      }).join(', ');
      out.writeln(
        'position after ${game.moveLabel(ply)}: ${pos.turn == Side.white ? 'White' : 'Black'} to move, '
        'tablebase says ${data['category']} for the side to move'
        '${data['dtm'] != null ? ', mate in ${(data['dtm'] as num).abs()} plies' : ''}; best: $best',
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return out.isEmpty ? 'Tablebase: unavailable right now.' : out.toString();
  }

  static String _tbCategoryAfter(String? c) => switch (c) {
    'loss' || 'maybe-loss' || 'blessed-loss' => 'win',
    'win' || 'maybe-win' || 'cursed-win' => 'loss',
    'draw' => 'draw',
    _ => c ?? 'unknown',
  };

  static String _bare(String san) => san.replaceAll(RegExp(r'[+#!?]'), '');
}

/// A compact, model-readable description of the game and its engine analysis.
String buildGameData(
  GameRecord game,
  GameAnalysis analysis, {
  required Side? perspective,
  String? openings,
  String? endgames,
}) {
  final b = StringBuffer()
    ..writeln('GAME')
    ..writeln('White: ${game.white.display}')
    ..writeln('Black: ${game.black.display}')
    ..writeln('Time control: ${game.speed ?? 'unknown'}')
    ..writeln('Result: ${game.result.label}${game.status != null ? ' (${game.status})' : ''}')
    ..writeln('Opening (Lichess): ${game.openingName ?? 'unknown'}')
    ..writeln(
      perspective == null
          ? 'Perspective: neutral. The app user did not play in this game; cover both players.'
          : 'Perspective: the app user played ${perspective == Side.white ? 'White' : 'Black'}. '
                'Write to them ("you") about their moves and describe the opponent\'s moves in '
                'the third person.',
    )
    ..writeln()
    ..writeln(
      'MOVES. Each line: ply | move | how good it was | what the move changed on the board | the '
      'better move and what its line achieves (only when the move was not best). "[rank: x->y]" '
      'is the engine score before and after (White\'s view), for your ranking only; never quote it.',
    );

  final castled = <Side>{};
  final keyPlies = _keyPlies(game, analysis);
  for (var ply = 1; ply <= game.plyCount; ply++) {
    final before = game.positions[ply - 1];
    final after = game.positions[ply];
    final move = game.moves[ply - 1];
    final quality = analysis.qualityOf(ply);
    final mover = before.turn == Side.white ? 'White' : 'Black';
    final changed = PositionFacts.move(before, move, after);
    final bestSan = analysis.bestSanAt(ply - 1);
    final wasBest = quality == MoveQuality.best || bestSan == null;
    final bestLine = wasBest || analysis.evals.length <= ply - 1
        ? ''
        : PositionFacts.line(before, analysis.evals[ply - 1].pv);
    final e0 = analysis.evalAt(ply - 1)?.label ?? '?';
    final e1 = analysis.evalAt(ply)?.label ?? '?';
    b.writeln(
      'ply $ply | ${game.moveLabel(ply)} ($mover) | ${quality?.label ?? '?'} [rank: $e0->$e1]'
      ' | $changed${bestLine.isNotEmpty ? ' | better: $bestSan ($bestLine)' : ''}',
    );
    if (game.sans[ply - 1].startsWith('O-O')) castled.add(before.turn);
  }

  // Deep dives: the full picture around the moves that matter most.
  b
    ..writeln()
    ..writeln(
      'KEY POSITIONS (full board facts before the move, and what the opponent\'s best reply '
      'does after it)',
    );
  final castledBy = <int, Set<Side>>{};
  final running = <Side>{};
  for (var ply = 1; ply <= game.plyCount; ply++) {
    castledBy[ply] = Set.of(running);
    if (game.sans[ply - 1].startsWith('O-O')) running.add(game.positions[ply - 1].turn);
  }
  for (final ply in keyPlies) {
    final before = game.positions[ply - 1];
    final after = game.positions[ply];
    final reply = analysis.evals.length > ply
        ? PositionFacts.line(after, analysis.evals[ply].pv)
        : '';
    b
      ..writeln()
      ..writeln('== Before ${game.moveLabel(ply)} (ply $ply), ${before.turn == Side.white ? 'White' : 'Black'} to move ==')
      ..writeln(PositionFacts.diagram(before))
      ..writeln(
        PositionFacts.position(before, castled: castledBy[ply] ?? const {}, opening: ply <= 24),
      );
    if (reply.isNotEmpty) b.writeln('- After ${game.sans[ply - 1]}, the best reply line: $reply');
  }
  if (openings != null) {
    b
      ..writeln()
      ..writeln('OPENING EXPLORER (Lichess masters database)')
      ..writeln(openings);
  }
  if (endgames != null) {
    b
      ..writeln()
      ..writeln('ENDGAME TABLEBASE (Lichess)')
      ..writeln(endgames);
  }
  b
    ..writeln()
    ..writeln('FINAL POSITION')
    ..writeln(PositionFacts.diagram(game.positions.last))
    ..writeln(PositionFacts.position(game.positions.last, castled: castled, opening: false));
  return b.toString();
}

/// The plies that deserve a deep dive: mistakes, the biggest swings, and a few checkpoints.
List<int> _keyPlies(GameRecord game, GameAnalysis analysis) {
  final n = game.plyCount;
  final scored = <(int, double)>[
    for (var p = 1; p <= n; p++) (p, analysis.lossOf(p)),
  ]..sort((a, b) => b.$2.compareTo(a.$2));
  final chosen = <int>{
    for (final (p, loss) in scored.take(10))
      if (loss >= 0.08) p,
  };
  // Checkpoints so quiet games still get position-level context.
  for (var p = 12; p <= n; p += 16) {
    chosen.add(p);
  }
  return (chosen.toList()..sort()).take(16).toList();
}

/// Checks one comment against the game. Returns the cleaned comment and, if it can't be used, why.
(MoveComment, String?) validateComment(GameRecord game, GameAnalysis analysis, MoveComment m) {
  final ply = m.ply;
  if (ply < 1 || ply > game.plyCount) return (m, 'ply out of range');

  // Positions any move in the comment could reasonably refer to.
  final contexts = <Position>[
    game.positions[ply - 1],
    game.positions[ply],
    if (ply + 1 < game.positions.length) game.positions[ply + 1],
    ..._positionsAlong(game.positions[ply - 1], analysis.evals.length > ply - 1 ? analysis.evals[ply - 1].pv : const []),
    ..._positionsAlong(game.positions[ply], analysis.evals.length > ply ? analysis.evals[ply].pv : const []),
  ];
  for (final token in _pieceMoveTokens(m.comment)) {
    final ok = contexts.any((p) => p.parseSan(token) != null);
    if (!ok) return (m, 'mentions $token, which is not legal around this move');
  }

  // Keep only arrows that start on a square holding a piece before or after the move.
  final before = game.positions[ply - 1].board;
  final after = game.positions[ply].board;
  final arrows = [
    for (final a in m.arrows)
      if (before.pieceAt(a.from) != null || after.pieceAt(a.from) != null) a,
  ];
  final quality = analysis.qualityOf(ply);
  final label = const ['best', 'good', 'inaccuracy', 'mistake', 'blunder', 'brilliant']
          .contains(m.label?.toLowerCase())
      ? m.label!.toLowerCase()
      : quality?.label.toLowerCase();
  return (
    MoveComment(
      ply: ply,
      san: game.sans[ply - 1],
      comment: m.comment,
      label: label,
      phase: m.phase,
      themes: m.themes.take(4).toList(),
      arrows: arrows,
      highlights: m.highlights,
    ),
    null,
  );
}

Iterable<Position> _positionsAlong(Position start, List<String> uci) sync* {
  var pos = start;
  for (final u in uci.take(6)) {
    final move = Move.parse(u);
    if (move == null || !pos.isLegal(move)) return;
    pos = pos.play(move);
    yield pos;
  }
}

/// Piece moves, captures and castling written in SAN inside prose (e.g. "Nf3", "Bxe5", "exd5",
/// "O-O"). Plain pawn pushes like "e4" are skipped because they read the same as square names.
Iterable<String> _pieceMoveTokens(String text) sync* {
  final re = RegExp(r'(?<![A-Za-z0-9])(O-O-O|O-O|[KQRBN][a-h]?[1-8]?x?[a-h][1-8]|[a-h]x[a-h][1-8](?:=[QRBN])?)(?![A-Za-z0-9])');
  for (final m in re.allMatches(text)) {
    yield m.group(1)!;
  }
}

const _reviewInstructions = '''
TASK: write a review of the game below for the app's review screen, by calling submit_review.

- "moves": one entry per ply you are asked about. Spend your words where they matter:
  - Mistakes, blunders, inaccuracies, key moments and critical decisions get a full note of 3-4
    sentences: what the move did on the board, what it overlooked or allowed (use the board facts
    and the best reply line), what the better move was and concretely why it was better, and the
    lesson in it.
  - Other moves get 1-2 clear sentences about the idea: which piece, which squares or files, what
    it prepares, attacks or defends. Book moves can be brief but still say what they are for.
  - Never justify a move by its evaluation. Explain it with the position.
- "label": best, good, inaccuracy, mistake, blunder or brilliant. Follow the quality given for the
  ply unless you have a clear, data-backed reason (use "brilliant" only for a best move that is a
  sound sacrifice).
- "phase": opening, middlegame or endgame. "themes": up to 3 short tags like "tactics: fork" or
  "positional: weak d5 square".
- "arrows": up to 2 per move, only when they make the note clearer: the better move (green), the
  threat or the problem (red), a plan or idea (blue). Squares in lowercase, e.g. g1 -> f3.
  "highlights": up to 2 key squares or pieces the note talks about.
- "summary": 3-5 sentences telling the story of the game in chess terms: how the opening went,
  where the balance shifted and why (on the board), and how it ended.
- "opening": the opening and variation, the ply where the game left master theory (from the
  explorer data, or null if unknown), and 2-3 sentences on the typical plans and pawn structure.
- "key_moments": 3-6 ply numbers of the real turning points.
- "recap": how the game was won, lost or drawn, in chess terms, then 2-4 practical lessons, each
  tagged with an area: tactics, strategy, positional, opening or endgame. Lessons should be
  habits the player can apply next game, tied to what happened in this one.

Only mention moves that appear in the game or in the lines given for that ply.''';

const _submitReviewTool = {
  'name': 'submit_review',
  'description': 'Submit the review of the game (or of the requested plies).',
  'input_schema': {
    'type': 'object',
    'properties': {
      'summary': {'type': 'string'},
      'opening': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
          'left_theory_at_ply': {
            'type': ['integer', 'null'],
          },
          'ideas': {'type': 'string'},
        },
      },
      'key_moments': {
        'type': 'array',
        'items': {'type': 'integer'},
      },
      'moves': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'ply': {'type': 'integer'},
            'san': {'type': 'string'},
            'phase': {
              'type': 'string',
              'enum': ['opening', 'middlegame', 'endgame'],
            },
            'label': {
              'type': 'string',
              'enum': ['best', 'good', 'inaccuracy', 'mistake', 'blunder', 'brilliant'],
            },
            'themes': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'comment': {'type': 'string'},
            'arrows': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'from': {'type': 'string'},
                  'to': {'type': 'string'},
                  'color': {
                    'type': 'string',
                    'enum': ['green', 'red', 'blue', 'yellow'],
                  },
                },
                'required': ['from', 'to'],
              },
            },
            'highlights': {
              'type': 'array',
              'items': {'type': 'string'},
            },
          },
          'required': ['ply', 'comment'],
        },
      },
      'recap': {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
          'lessons': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'area': {
                  'type': 'string',
                  'enum': ['tactics', 'strategy', 'positional', 'opening', 'endgame'],
                },
                'lesson': {'type': 'string'},
              },
              'required': ['area', 'lesson'],
            },
          },
        },
      },
    },
    'required': ['moves'],
  },
};

