import 'dart:async';

import 'package:dartchess/dartchess.dart';

import '../engine/game_analysis.dart';
import '../engine/stockfish_engine.dart';
import '../game_record.dart';
import '../lichess_client.dart';
import '../settings.dart';
import '../storage.dart';
import 'claude_client.dart';
import 'coach_models.dart';
import 'narration.dart';
import 'usage.dart';

/// One message as shown in the chatbox.
class ChatMessage {
  const ChatMessage({required this.fromUser, required this.text, this.sources = const [], this.at});

  final bool fromUser;
  final String text;

  /// Short notes on the tools the Professor used ("Stockfish, depth 18", "Lichess masters").
  final List<String> sources;
  final DateTime? at;

  Map<String, dynamic> toJson() => {
    'user': fromUser,
    'text': text,
    'sources': sources,
    if (at != null) 'at': at!.toIso8601String(),
  };

  static ChatMessage fromJson(Map<String, dynamic> j) => ChatMessage(
    fromUser: j['user'] as bool? ?? false,
    text: j['text'] as String? ?? '',
    sources: [for (final s in (j['sources'] as List? ?? const [])) s as String],
    at: DateTime.tryParse(j['at'] as String? ?? ''),
  );
}

/// What's on the board when a question is asked.
class BoardContext {
  const BoardContext({
    required this.ply,
    required this.position,
    required this.label,
    this.variation = const [],
  });

  final int ply;
  final Position position;
  final String label;

  /// Moves played away from the game, in SAN, starting after [ply].
  final List<String> variation;
}

/// A persistent coach conversation about one game.
class ChatSession {
  ChatSession._(this.game, this._store, this._raw, this.messages);

  final GameRecord game;
  final LocalStore _store;

  /// API-format history (including tool calls), trimmed to recent turns.
  final List<Map<String, dynamic>> _raw;
  final List<ChatMessage> messages;

  static Future<ChatSession> load(GameRecord game, LocalStore store) async {
    final j = await store.read('chat', gameKey(game));
    final raw = <Map<String, dynamic>>[];
    final msgs = <ChatMessage>[];
    if (j != null) {
      try {
        for (final m in (j['raw'] as List? ?? const [])) {
          raw.add((m as Map).cast<String, dynamic>());
        }
        for (final m in (j['messages'] as List? ?? const [])) {
          msgs.add(ChatMessage.fromJson((m as Map).cast()));
        }
      } catch (_) {
        raw.clear();
        msgs.clear();
      }
    }
    return ChatSession._(game, store, raw, msgs);
  }

  Future<void> save() => _store.write('chat', gameKey(game), {
    'raw': _raw,
    'messages': [for (final m in messages) m.toJson()],
  });

  Future<void> clear() async {
    _raw.clear();
    messages.clear();
    await _store.delete('chat', gameKey(game));
  }
}

/// Runs chat turns: Claude answers, calling on-device Stockfish and Lichess lookups as needed.
class ChatService {
  ChatService({
    required this.claude,
    required this.lichess,
    required this.settings,
    required this.usage,
    StockfishEngine? engine,
  }) : engine = engine ?? StockfishEngine.instance;

  final ClaudeClient claude;
  final LichessClient lichess;
  final AppSettings settings;
  final UsageTracker usage;
  final StockfishEngine engine;

  static const _maxToolRounds = 6;
  static const _keepRawMessages = 40;

  /// Asks [question] about the position in [board]. Adds both messages to [session] and saves it.
  Future<ChatMessage> ask(
    ChatSession session,
    String question, {
    required BoardContext board,
    required GameAnalysis? analysis,
    required CoachReview? review,
    void Function(String status)? onStatus,
  }) async {
    if (!settings.hasApiKey) {
      throw const ClaudeException('Add your Anthropic API key in Settings to chat with the coach.');
    }
    final capped = usage.capReached;
    if (capped != null) throw ClaudeException(capped);

    final game = session.game;
    session.messages.add(ChatMessage(fromUser: true, text: question, at: DateTime.now()));

    final side = game.sideOf(settings.username);
    final gameData = analysis != null && analysis.isComplete
        ? buildGameData(game, analysis, perspective: side)
        : _plainGameData(game, side);
    final reviewText = review == null
        ? 'The Professor has not written a full review of this game yet.'
        : 'YOUR EARLIER REVIEW\nSummary: ${review.summary}\nRecap: ${review.recapText}\nLessons: '
              '${review.lessons.map((l) => '${l.area}: ${l.lesson}').join(' | ')}';

    final system = [
      {'type': 'text', 'text': '$kProfessorPersona\n\n$_chatInstructions'},
      {
        'type': 'text',
        'text': '$gameData\n\n$reviewText',
        'cache_control': {'type': 'ephemeral'},
      },
    ];

    final where = StringBuffer()
      ..writeln('[Board: ${board.label} (ply ${board.ply}).')
      ..writeln(' FEN: ${board.position.fen}')
      ..writeln(' ${board.position.turn == Side.white ? 'White' : 'Black'} to move.');
    if (board.variation.isNotEmpty) {
      where.writeln(' The user is exploring a side line from the game: ${board.variation.join(' ')}.');
    }
    where.write(']');

    final pending = <Map<String, dynamic>>[
      ...session._raw,
      {
        'role': 'user',
        'content': '$where\n\n$question',
      },
    ];

    var total = const TokenUsage();
    final sources = <String>{};
    final seenLines = <List<String>>[];
    String answer = '';

    try {
      for (var round = 0; round <= _maxToolRounds; round++) {
        onStatus?.call(round == 0 ? 'Thinking…' : 'Checking with ${sources.lastOrNull ?? 'Stockfish'}…');
        final res = await claude.send(
          system: system,
          messages: pending,
          tools: _chatTools,
          maxTokens: 1500,
          timeout: const Duration(minutes: 2),
        );
        total += res.usage;
        pending.add({'role': 'assistant', 'content': res.content});
        final uses = res.toolUses;
        if (res.stopReason != 'tool_use' || uses.isEmpty || round == _maxToolRounds) {
          answer = res.text;
          break;
        }
        final results = <Map<String, dynamic>>[];
        for (final use in uses) {
          final name = use['name'] as String? ?? '';
          final input = (use['input'] as Map?)?.cast<String, dynamic>() ?? const {};
          onStatus?.call(_statusFor(name));
          final (text, source, lines) = await _runTool(name, input);
          if (source != null) sources.add(source);
          seenLines.addAll(lines);
          results.add({'type': 'tool_result', 'tool_use_id': use['id'], 'content': text});
        }
        pending.add({'role': 'user', 'content': results});
      }

      // One correction round if the answer names a move that isn't legal anywhere relevant.
      final bad = _illegalMoves(answer, board, game, seenLines);
      if (bad.isNotEmpty) {
        onStatus?.call('Double-checking the moves…');
        pending.add({
          'role': 'user',
          'content':
              'Your answer mentions ${bad.join(', ')}, which is not a legal move in the positions '
              'under discussion. Please correct the answer (check with analyze_position if '
              'needed) and reply with the corrected answer only.',
        });
        final res = await claude.send(system: system, messages: pending, tools: _chatTools, maxTokens: 1500);
        total += res.usage;
        pending.add({'role': 'assistant', 'content': res.content});
        if (res.text.isNotEmpty) answer = res.text;
      }
    } finally {
      final cost = total.costFor(settings.model);
      if (cost > 0) {
        await usage.record(kind: 'Chat', label: _gameLabel(game, side), cost: cost);
      }
    }

    if (answer.isEmpty) answer = 'Sorry, I could not come up with an answer to that. Try asking another way.';
    final reply = ChatMessage(fromUser: false, text: answer, sources: sources.toList(), at: DateTime.now());
    session.messages.add(reply);

    // Store a compact history: the question and the final answer, without the tool traffic.
    session._raw
      ..add({'role': 'user', 'content': '$where\n\n$question'})
      ..add({'role': 'assistant', 'content': answer});
    if (session._raw.length > _keepRawMessages) {
      session._raw.removeRange(0, session._raw.length - _keepRawMessages);
    }
    await session.save();
    return reply;
  }

  String _statusFor(String tool) => switch (tool) {
    'analyze_position' => 'Running Stockfish…',
    'lichess_opening_explorer' => 'Looking up the opening explorer…',
    'lichess_tablebase' => 'Checking the endgame tablebase…',
    _ => 'Looking it up on Lichess…',
  };

  Future<(String, String?, List<List<String>>)> _runTool(String name, Map<String, dynamic> input) async {
    try {
      switch (name) {
        case 'analyze_position':
          return await _analyzePosition(input);
        case 'lichess_opening_explorer':
          final fen = input['fen'] as String? ?? '';
          final source = input['source'] as String? ?? 'masters';
          final data = await lichess.openingExplorer(
            fen,
            source: source,
            speeds: (input['speeds'] as List?)?.cast<String>(),
            ratings: (input['ratings'] as List?)?.map((e) => (e as num).toInt()).toList(),
            player: input['player'] as String?,
            color: input['color'] as String?,
            moves: 8,
          );
          if (data == null) return ('The opening explorer is unavailable right now.', null, const <List<String>>[]);
          return (_explorerText(data), 'Lichess ${source == 'player' ? 'player' : source} explorer', const <List<String>>[]);
        case 'lichess_tablebase':
          final data = await lichess.tablebase(input['fen'] as String? ?? '');
          if (data == null) return ('The tablebase has no answer for that position (it needs 7 or fewer pieces).', null, const <List<String>>[]);
          final moves = (data['moves'] as List? ?? const []).cast<Map>().take(6).map((m) {
            return '${m['san']}: ${m['category']} for the opponent after it${m['dtz'] != null ? ' (dtz ${m['dtz']})' : ''}';
          }).join('; ');
          return (
            'Side to move: ${data['category']}${data['dtm'] != null ? ', dtm ${data['dtm']}' : ''}. Moves: $moves',
            'Lichess tablebase',
            const <List<String>>[],
          );
        case 'lichess_user':
          final u = await lichess.user(input['username'] as String? ?? '');
          if (u == null) return ('No such Lichess player.', null, const <List<String>>[]);
          final perfs = (u['perfs'] as Map? ?? const {}).entries
              .where((e) => e.value is Map && (e.value as Map)['games'] != null)
              .map((e) => '${e.key}: ${(e.value as Map)['rating']} (${(e.value as Map)['games']} games)')
              .join(', ');
          return ('${u['username']}: $perfs', 'Lichess profile', const <List<String>>[]);
        case 'lichess_rating_history':
          final hist = await lichess.ratingHistory(input['username'] as String? ?? '');
          final perf = (input['perf'] as String?)?.toLowerCase();
          final out = StringBuffer();
          for (final h in hist) {
            if (h is! Map) continue;
            final n = (h['name'] as String? ?? '').toLowerCase();
            if (perf != null && n != perf) continue;
            final points = (h['points'] as List? ?? const []);
            if (points.isEmpty) continue;
            final recent = points.skip(points.length > 12 ? points.length - 12 : 0).map((p) {
              final l = p as List;
              return '${l[0]}-${(l[1] as num).toInt() + 1}-${l[2]}: ${l[3]}';
            }).join(', ');
            out.writeln('${h['name']}: $recent');
          }
          return (out.isEmpty ? 'No rating history found.' : out.toString(), 'Lichess rating history', const <List<String>>[]);
        case 'lichess_user_games':
          final games = await lichess.filteredGames(
            input['username'] as String? ?? '',
            max: (input['max'] as num?)?.toInt() ?? 8,
            perfType: input['perf_type'] as String?,
            vs: input['vs'] as String?,
          );
          if (games.isEmpty) return ('No matching games.', null, const <List<String>>[]);
          final text = games.map((g) {
            final date = g.playedAt?.toIso8601String().substring(0, 10) ?? '';
            return '$date ${g.white.display} vs ${g.black.display}, ${g.result.label}, '
                '${g.speed ?? ''}, ${g.openingName ?? ''}: ${g.sans.take(16).join(' ')}';
          }).join('\n');
          return (text, 'Lichess games', const <List<String>>[]);
      }
      return ('Unknown tool $name.', null, const <List<String>>[]);
    } on LichessException catch (e) {
      return (e.message, null, const <List<String>>[]);
    } on EngineException catch (e) {
      return (e.message, null, const <List<String>>[]);
    } catch (e) {
      return ('The tool failed: $e', null, const <List<String>>[]);
    }
  }

  Future<(String, String?, List<List<String>>)> _analyzePosition(Map<String, dynamic> input) async {
    Position pos;
    try {
      pos = Chess.fromSetup(Setup.parseFen((input['fen'] as String? ?? '').trim()));
    } catch (_) {
      return ('That FEN could not be read.', null, const <List<String>>[]);
    }
    final applied = <String>[];
    for (final raw in (input['moves'] as List? ?? const [])) {
      final m = raw.toString().trim();
      final move = pos.parseSan(m) ?? Move.parse(m);
      if (move == null || !pos.isLegal(move)) {
        return ('The move "$m" is not legal in that position (after: ${applied.join(' ')}).', null, const <List<String>>[]);
      }
      final (next, san) = pos.makeSan(move);
      applied.add(san);
      pos = next;
    }
    if (pos.isCheckmate) return ('That position is checkmate.', 'Stockfish', const <List<String>>[]);
    if (pos.isStalemate) return ('That position is stalemate (a draw).', 'Stockfish', const <List<String>>[]);
    final depth = ((input['depth'] as num?)?.toInt() ?? 18).clamp(10, 22);
    final lines = await engine.analyze(
      pos.fen,
      depth: depth,
      movetime: const Duration(milliseconds: 2500),
      multiPv: 3,
      interactive: true,
    );
    final sanLines = <List<String>>[];
    final out = StringBuffer()
      ..writeln(applied.isEmpty ? 'Position as given.' : 'After ${applied.join(' ')}:')
      ..writeln('${pos.turn == Side.white ? 'White' : 'Black'} to move.');
    for (var i = 0; i < lines.length; i++) {
      final san = uciLineToSan(pos, lines[i].pv.take(8).toList());
      sanLines.add(san);
      out.writeln('${i + 1}) ${lines[i].eval.label} (depth ${lines[i].depth}): ${san.join(' ')}');
    }
    return (out.toString(), 'Stockfish', sanLines);
  }

  String _explorerText(Map<String, dynamic> d) {
    num total(Map m) => (m['white'] as num? ?? 0) + (m['draws'] as num? ?? 0) + (m['black'] as num? ?? 0);
    final all = total(d);
    final moves = (d['moves'] as List? ?? const []).cast<Map>().map((m) {
      final t = total(m);
      String pct(String k) => t == 0 ? '0' : ((m[k] as num? ?? 0) * 100 / t).round().toString();
      return '${m['san']}: $t games (White ${pct('white')}% / draw ${pct('draws')}% / Black ${pct('black')}%)'
          '${m['averageRating'] != null ? ', avg rating ${m['averageRating']}' : ''}';
    }).join('\n');
    final name = (d['opening'] as Map?)?['name'];
    return '${name != null ? 'Opening: $name\n' : ''}Games in this position: $all\n$moves';
  }

  /// Piece moves in [answer] that aren't legal in any position reasonably under discussion.
  List<String> _illegalMoves(String answer, BoardContext board, GameRecord game, List<List<String>> lines) {
    final contexts = <Position>[board.position];
    for (var p = board.ply - 2; p <= board.ply + 3; p++) {
      if (p >= 0 && p < game.positions.length) contexts.add(game.positions[p]);
    }
    for (final line in lines) {
      var pos = board.position;
      for (final san in line) {
        final mv = pos.parseSan(san);
        if (mv == null) break;
        pos = pos.play(mv);
        contexts.add(pos);
      }
    }
    final re = RegExp(r'(?<![A-Za-z0-9])(O-O-O|O-O|[KQRBN][a-h]?[1-8]?x?[a-h][1-8]|[a-h]x[a-h][1-8](?:=[QRBN])?)(?![A-Za-z0-9])');
    final bad = <String>{};
    for (final m in re.allMatches(answer)) {
      final token = m.group(1)!;
      if (!contexts.any((p) => p.parseSan(token) != null)) bad.add(token);
    }
    return bad.take(5).toList();
  }

  String _plainGameData(GameRecord game, Side? side) {
    final moves = [for (var p = 1; p <= game.plyCount; p++) game.moveLabel(p)].join(' ');
    return 'GAME\nWhite: ${game.white.display}\nBlack: ${game.black.display}\n'
        'Time control: ${game.speed ?? 'unknown'}\nResult: ${game.result.label}\n'
        '${side == null ? 'Perspective: neutral.' : 'The app user played ${side == Side.white ? 'White' : 'Black'}.'}\n'
        'Moves: $moves\n(Engine analysis of the game is still running; use analyze_position for evaluations.)';
  }

  static String _gameLabel(GameRecord game, Side? side) =>
      side == null ? '${game.white.name} vs ${game.black.name}' : 'vs ${game.opponentOf(side).name}';
}

const _chatInstructions = '''
TASK: answer the user's questions in the chatbox of the review screen. Each question starts with
the position currently on their board (FEN, move label, and any side line they are exploring).

- Keep answers short: 2-5 sentences, plain text, no markdown headings or tables.
- For anything about a concrete position (evaluations, best moves, "what if I played X"), call
  analyze_position on the on-device Stockfish and base the answer on its output. You may chain
  several calls to compare lines. Quote the key numbers, e.g. "Nf3 keeps +0.4 at depth 18, while
  Bg5 drops to -1.2 because of ...Qb6."
- Use the Lichess tools only when a question needs data the engine can't give: how popular a line
  is or what masters play (opening explorer), perfect endgame play (tablebase), or facts about a
  player (profile, rating history, recent games). Say where the data came from.
- Never guess at evaluations or statistics. If a tool fails, say so briefly.''';

const _chatTools = [
  {
    'name': 'analyze_position',
    'description':
        'Run Stockfish 16 on the phone. Give a FEN and optionally moves (SAN or UCI) to play from '
        'it first. Returns the evaluation (White\'s view) and the top 3 engine lines in SAN.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'fen': {'type': 'string'},
        'moves': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'depth': {'type': 'integer', 'minimum': 10, 'maximum': 22},
      },
      'required': ['fen'],
    },
  },
  {
    'name': 'lichess_opening_explorer',
    'description':
        'How often each move is played in a position, with results. source: masters (OTB master '
        'games), lichess (all Lichess games; filter with speeds and ratings) or player (one '
        'player\'s games; give player and color).',
    'input_schema': {
      'type': 'object',
      'properties': {
        'fen': {'type': 'string'},
        'source': {
          'type': 'string',
          'enum': ['masters', 'lichess', 'player'],
        },
        'speeds': {
          'type': 'array',
          'items': {
            'type': 'string',
            'enum': ['ultraBullet', 'bullet', 'blitz', 'rapid', 'classical', 'correspondence'],
          },
        },
        'ratings': {
          'type': 'array',
          'items': {'type': 'integer'},
          'description': 'Rating group lower bounds, e.g. [1600, 1800].',
        },
        'player': {'type': 'string'},
        'color': {
          'type': 'string',
          'enum': ['white', 'black'],
        },
      },
      'required': ['fen'],
    },
  },
  {
    'name': 'lichess_tablebase',
    'description': 'Perfect-play verdict and best moves for positions with 7 or fewer pieces.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'fen': {'type': 'string'},
      },
      'required': ['fen'],
    },
  },
  {
    'name': 'lichess_user',
    'description': 'A player\'s profile: current ratings and game counts per time control.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'username': {'type': 'string'},
      },
      'required': ['username'],
    },
  },
  {
    'name': 'lichess_rating_history',
    'description': 'A player\'s recent rating history, optionally for one time control.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'username': {'type': 'string'},
        'perf': {'type': 'string', 'description': 'e.g. Blitz, Rapid, Bullet, Classical'},
      },
      'required': ['username'],
    },
  },
  {
    'name': 'lichess_user_games',
    'description':
        'A player\'s recent games (opening, result, first moves), optionally filtered by time '
        'control (perf_type) or opponent (vs).',
    'input_schema': {
      'type': 'object',
      'properties': {
        'username': {'type': 'string'},
        'max': {'type': 'integer', 'minimum': 1, 'maximum': 15},
        'perf_type': {
          'type': 'string',
          'enum': ['bullet', 'blitz', 'rapid', 'classical', 'correspondence'],
        },
        'vs': {'type': 'string'},
      },
      'required': ['username'],
    },
  },
];
