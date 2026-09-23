import 'dart:async';

import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../coach/chat.dart';
import '../coach/claude_client.dart';
import '../coach/coach_models.dart';
import '../coach/narration.dart';
import '../coach/pgn_export.dart';
import '../coach/usage.dart';
import '../engine/eval.dart';
import '../engine/game_analysis.dart';
import '../engine/stockfish_engine.dart';
import '../game_record.dart';
import '../lichess_client.dart';
import '../services.dart';
import '../theme.dart';
import '../widgets/eval_bar.dart';
import '../widgets/eval_graph.dart';
import '../widgets/move_strip.dart';
import 'settings_screen.dart';

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

/// How a Guess the move attempt went.
class GuessResult {
  const GuessResult({
    required this.ply,
    required this.guessSan,
    required this.playedSan,
    required this.bestSan,
    required this.verdict,
    required this.guessEval,
    required this.bestEval,
    required this.good,
  });

  /// The ply of the game move that was being guessed (1-based).
  final int ply;
  final String guessSan;
  final String playedSan;
  final String? bestSan;
  final String verdict;
  final Eval? guessEval;
  final Eval? bestEval;
  final bool good;
}

/// The review screen: board, Stockfish analysis, the Professor's commentary, Guess the move and
/// the coach chat.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.game});

  final GameRecord game;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  GameRecord get game => widget.game;

  int _ply = 0;
  late Side _orientation = game.sideOf(services.settings.username) ?? Side.white;

  // Engine analysis.
  GameAnalysis? _analysis;
  StreamSubscription<GameAnalysis>? _analysisSub;
  String? _engineError;

  // Exploration away from the game's moves.
  int? _branchPly;
  final List<VariationMove> _variation = [];
  PositionEval? _liveEval;
  int _liveToken = 0;

  // Coach review.
  CoachReview? _review;
  ReviewStage? _coachStage;
  String? _coachError;
  bool _showArrows = true;

  // Guess the move.
  bool _guessOn = false;
  bool _awaitingGuess = false;
  bool _grading = false;
  GuessResult? _guess;

  // Chat.
  ChatSession? _chat;
  bool _chatOpen = false;
  bool _chatBusy = false;
  String? _chatStatus;
  String? _chatError;
  final _chatInput = TextEditingController();
  final _chatScroll = ScrollController();

  late final ChessboardController _board = ChessboardController(game: _gameData());

  Side? get _userSide => game.sideOf(services.settings.username);

  @override
  void initState() {
    super.initState();
    _startAnalysis();
    _loadCoach();
  }

  @override
  void dispose() {
    _analysisSub?.cancel();
    _board.dispose();
    _chatInput.dispose();
    _chatScroll.dispose();
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

  Future<void> _loadCoach() async {
    final review = await services.coach.cached(game);
    final chat = await ChatSession.load(game, services.store);
    if (!mounted) return;
    setState(() {
      _review = review;
      _chat = chat;
    });
  }

  // ---- Displayed position ----

  bool get _exploring => _variation.isNotEmpty;

  Position get _position => _exploring ? _variation.last.after : game.positions[_ply];

  Move? get _lastMove =>
      _exploring ? _variation.last.move : (_ply > 0 ? game.moves[_ply - 1] : null);

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

  void _go(int ply, {bool keepGuess = false}) {
    setState(() {
      _variation.clear();
      _branchPly = null;
      _liveEval = null;
      _awaitingGuess = false;
      if (!keepGuess) _guess = null;
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
    if (_exploring) return;
    if (_ply >= game.plyCount) return;
    if (_guessOn && !_awaitingGuess && _shouldGuess(_ply)) {
      setState(() {
        _awaitingGuess = true;
        _guess = null;
        _chatOpen = false;
      });
      return;
    }
    _go(_ply + 1);
  }

  /// Whether the user guesses the move played from positions[ply].
  bool _shouldGuess(int ply) {
    final side = _userSide;
    return side == null || game.positions[ply].turn == side;
  }

  void _onBoardMove(Move move, {bool? viaDragAndDrop}) {
    final pos = _position;
    if (!pos.isLegal(move)) return;
    final (after, san) = pos.makeSan(move);
    if (_awaitingGuess) {
      _gradeGuess(move, san, after);
      return;
    }
    if (!_exploring && _ply < game.plyCount && _bare(san) == _bare(game.sans[_ply])) {
      _go(_ply + 1);
      return;
    }
    setState(() {
      _branchPly ??= _ply;
      _variation.add(VariationMove(move, san, after));
      _guess = null;
    });
    _syncBoard();
    _refreshLiveEval();
  }

  Future<void> _gradeGuess(Move move, String san, Position after) async {
    final ply = _ply;
    final played = game.sans[ply];
    final mover = game.positions[ply].turn;
    final sign = mover == Side.white ? 1 : -1;
    setState(() => _grading = true);
    // Show the guess on the board while grading.
    _board.updatePosition(
      GameData(
        fen: after.fen,
        lastMove: move,
        playerSide: PlayerSide.none,
        sideToMove: after.turn,
        validMoves: const {},
      ),
    );

    Eval? bestEval = _analysis?.evalAt(ply);
    String? bestSan = _analysis?.bestSanAt(ply);
    Eval? guessEval;
    try {
      if (bestEval == null || bestSan == null) {
        final lines = await StockfishEngine.instance.analyze(
          game.positions[ply].fen,
          depth: 16,
          movetime: const Duration(milliseconds: 1000),
          interactive: true,
        );
        bestEval = lines.first.eval;
        bestSan = uciLineToSan(game.positions[ply], lines.first.pv.take(1).toList()).firstOrNull;
      }
      if (after.isCheckmate) {
        guessEval = Eval.checkmate(whiteWon: mover == Side.white);
      } else if (after.isStalemate) {
        guessEval = const Eval.cp(0);
      } else if (_bare(san) == _bare(played) && _analysis?.evalAt(ply + 1) != null) {
        guessEval = _analysis!.evalAt(ply + 1);
      } else {
        final lines = await StockfishEngine.instance.analyze(
          after.fen,
          depth: 16,
          movetime: const Duration(milliseconds: 1000),
          interactive: true,
        );
        guessEval = lines.first.eval;
      }
    } on EngineException catch (e) {
      _engineError = e.message;
    }
    if (!mounted) return;

    final loss = (bestEval != null && guessEval != null)
        ? (bestEval.whiteWinChance - guessEval.whiteWinChance) * sign
        : null;
    final isBest = bestSan != null && _bare(bestSan) == _bare(san);
    final isPlayed = _bare(san) == _bare(played);
    final String verdict;
    final bool good;
    if (isBest) {
      verdict = 'Best move! That\'s Stockfish\'s choice.';
      good = true;
    } else if (loss == null) {
      verdict = isPlayed ? 'That\'s the move that was played.' : 'Couldn\'t grade that one.';
      good = isPlayed;
    } else if (loss < 0.03) {
      verdict = 'Excellent — as strong as the engine\'s choice.';
      good = true;
    } else if (loss < 0.1) {
      verdict = 'Good move.';
      good = true;
    } else if (loss < 0.2) {
      verdict = 'Inaccurate — there was something better.';
      good = false;
    } else if (loss < 0.3) {
      verdict = 'A mistake — it gives away a lot.';
      good = false;
    } else {
      verdict = 'A blunder — that loses significant ground.';
      good = false;
    }
    setState(() {
      _grading = false;
      _guess = GuessResult(
        ply: ply + 1,
        guessSan: san,
        playedSan: played,
        bestSan: bestSan,
        verdict: verdict,
        guessEval: guessEval,
        bestEval: bestEval,
        good: good,
      );
    });
    _go(ply + 1, keepGuess: true);
  }

  void _skipGuess() => _go(_ply + 1);

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
    if (pos.isStalemate) {
      setState(() => _liveEval = const PositionEval(eval: Eval.cp(0), pv: [], depth: 0));
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

  // ---- Coach ----

  Future<void> _runCoach({bool redo = false}) async {
    final analysis = _analysis;
    if (analysis == null || !analysis.isComplete) return;
    if (redo) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Redo the review?'),
          content: const Text(
            'The Professor will write a fresh review of this game. It costs about as much as the first one.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Redo')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() {
      _coachError = null;
      _coachStage = ReviewStage.preparing;
    });
    try {
      final review = await services.coach.review(
        game,
        analysis,
        onStage: (s) {
          if (mounted) setState(() => _coachStage = s);
        },
      );
      if (!mounted) return;
      setState(() {
        _review = review;
        _coachStage = null;
      });
      _go(0);
    } on ClaudeException catch (e) {
      if (mounted) {
        setState(() {
          _coachError = e.message;
          _coachStage = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _coachError = 'Something went wrong writing the review: $e';
          _coachStage = null;
        });
      }
    }
  }

  void _jumpKeyMoment(bool next) {
    final moments = _review?.keyMoments ?? const <int>[];
    if (moments.isEmpty) return;
    final target = next
        ? moments.where((m) => m > _ply).firstOrNull
        : moments.reversed.where((m) => m < _ply).firstOrNull;
    if (target != null) _go(target);
  }

  Set<Shape> get _shapes {
    final review = _review;
    if (!_showArrows || review == null || _exploring || _awaitingGuess || _ply == 0) return const {};
    final c = review.moves[_ply];
    if (c == null) return const {};
    return {
      for (final a in c.arrows) Arrow(color: a.paint, orig: a.from, dest: a.to),
      for (final h in c.highlights) Circle(color: const Color(0xCCE0A43A), orig: h),
    };
  }

  // ---- Export ----

  Future<void> _export() async {
    final review = _review;
    final messenger = ScaffoldMessenger.of(context);
    if (review == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Run Analyze with Coach first, then export the review.')),
      );
      return;
    }
    final settings = services.settings;
    final token = settings.lichessToken;
    final username = settings.username;
    if (token == null || username == null) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Connect a Lichess study token'),
          content: const Text(
            'Exporting saves the review into one of your Lichess studies. It needs a personal '
            'Lichess token with study access, which you can add in Settings.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
      if (go == true && mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SettingsScreen()),
        );
      }
      return;
    }

    List<(String, String)> studies;
    try {
      studies = await services.lichess.studies(username, token);
    } on LichessException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (!mounted) return;
    if (studies.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('No studies found. Create a study on lichess.org first, then export again.'),
        ),
      );
      return;
    }
    final last = settings.lastStudy?.split('|').first;
    studies.sort((a, b) => (a.$1 == last ? 0 : 1) - (b.$1 == last ? 0 : 1));
    final picked = await showDialog<(String, String)>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Export to which study?'),
        children: [
          for (final s in studies.take(30))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, s),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(s.$2 + (s.$1 == last ? '  (last used)' : '')),
              ),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final side = _userSide;
    final name = side == null
        ? '${game.white.name} vs ${game.black.name}'
        : 'vs ${game.opponentOf(side).name}${game.playedAt != null ? ' ${game.playedAt!.toLocal().toString().substring(0, 10)}' : ''}';
    try {
      final url = await services.lichess.importToStudy(picked.$1, annotatedPgn(game, review), name, token);
      await settings.setLastStudy(picked.$1, picked.$2);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Saved to "${picked.$2}".'),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
          ),
        ),
      );
    } on LichessException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  // ---- Chat ----

  BoardContext get _boardContext => BoardContext(
    ply: _exploring ? (_branchPly ?? _ply) : _ply,
    position: _position,
    label: _exploring
        ? 'side line from ${game.moveLabel(_branchPly ?? _ply)}: ${_variation.map((v) => v.san).join(' ')}'
        : game.moveLabel(_ply),
    variation: [for (final v in _variation) v.san],
  );

  Future<void> _sendChat() async {
    final q = _chatInput.text.trim();
    final session = _chat;
    if (q.isEmpty || session == null || _chatBusy) return;
    FocusScope.of(context).unfocus();
    _chatInput.clear();
    setState(() {
      _chatOpen = true;
      _chatBusy = true;
      _chatError = null;
      _chatStatus = 'Thinking…';
      _awaitingGuess = false;
    });
    _scrollChatToEnd();
    try {
      await services.chat.ask(
        session,
        q,
        board: _boardContext,
        analysis: _analysis,
        review: _review,
        onStatus: (s) {
          if (mounted) setState(() => _chatStatus = s);
        },
      );
    } catch (e) {
      // The session may already hold the question; take it back out so it can be re-sent.
      if (session.messages.isNotEmpty &&
          session.messages.last.fromUser &&
          session.messages.last.text == q) {
        session.messages.removeLast();
      }
      _chatInput.text = q;
      _chatError = e is ClaudeException ? e.message : 'Something went wrong: $e';
    }
    if (!mounted) return;
    setState(() {
      _chatBusy = false;
      _chatStatus = null;
    });
    _scrollChatToEnd();
  }

  void _scrollChatToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) {
        _chatScroll.animateTo(
          _chatScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _clearChat() async {
    await _chat?.clear();
    if (mounted) setState(() {});
  }

  // ---- UI ----

  Eval? get _shownEval => _exploring ? _liveEval?.eval : _analysis?.evalAt(_ply);

  @override
  Widget build(BuildContext context) {
    final analysis = _analysis;
    final review = _review;
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
    final keyMoments = {...?review?.keyMoments};

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${game.white.name} vs ${game.black.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (review != null)
            IconButton(
              tooltip: _showArrows ? 'Hide coach arrows' : 'Show coach arrows',
              icon: Icon(_showArrows ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              onPressed: () => setState(() => _showArrows = !_showArrows),
            ),
          IconButton(
            tooltip: 'Flip board',
            icon: const Icon(Icons.swap_vert),
            onPressed: () => setState(() => _orientation = _orientation.opposite),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'export':
                  _export();
                case 'redo':
                  _runCoach(redo: true);
                case 'clearchat':
                  _clearChat();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'export', child: Text('Export to Lichess study')),
              if (review != null && analysis?.isComplete == true && _coachStage == null)
                const PopupMenuItem(value: 'redo', child: Text('Redo coach review')),
              if ((_chat?.messages.isNotEmpty ?? false))
                const PopupMenuItem(value: 'clearchat', child: Text('Clear chat')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            const barWidth = 16.0;
            const gap = 6.0;
            final maxByWidth = constraints.maxWidth - barWidth - gap - 8;
            final maxByHeight = constraints.maxHeight * (_chatOpen ? 0.42 : 0.56);
            final boardSize = maxByWidth < maxByHeight ? maxByWidth : maxByHeight;
            return Column(
              children: [
                _Toolbar(
                  guessOn: _guessOn,
                  onGuessChanged: (v) => setState(() {
                    _guessOn = v;
                    if (!v) _awaitingGuess = false;
                    _guess = null;
                  }),
                  hasKeyMoments: keyMoments.isNotEmpty,
                  onPrevKey: () => _jumpKeyMoment(false),
                  onNextKey: () => _jumpKeyMoment(true),
                ),
                _PlayerLine(player: top),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    EvalBar(
                      eval: _awaitingGuess ? null : _shownEval,
                      orientation: _orientation,
                      height: boardSize,
                    ),
                    const SizedBox(width: gap),
                    Chessboard(
                      size: boardSize,
                      controller: _board,
                      orientation: _orientation,
                      onMove: _grading ? null : _onBoardMove,
                      shapes: _shapes,
                      settings: const ChessboardSettings(
                        enablePremoves: false,
                        animationDuration: Duration(milliseconds: 180),
                      ),
                    ),
                  ],
                ),
                _PlayerLine(player: bottom),
                MoveStrip(
                  game: game,
                  currentPly: _exploring ? (_branchPly ?? _ply) : _ply,
                  onSelectPly: _go,
                  colors: _awaitingGuess ? const {} : colors,
                  keyMoments: keyMoments,
                ),
                Expanded(
                  child: _chatOpen
                      ? _ChatHistory(
                          messages: _chat?.messages ?? const [],
                          busy: _chatBusy,
                          status: _chatStatus,
                          error: _chatError,
                          controller: _chatScroll,
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          children: [
                            if (_awaitingGuess)
                              _GuessPrompt(
                                label: game.moveLabel(_ply + 1).split(' ').first,
                                side: game.positions[_ply].turn,
                                grading: _grading,
                                onSkip: _skipGuess,
                              )
                            else ...[
                              if (_guess != null && _guess!.ply == _ply) _GuessCard(result: _guess!),
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
                              if (!_exploring)
                                _CoachPanel(
                                  game: game,
                                  ply: _ply,
                                  review: review,
                                  analysisComplete: analysis?.isComplete ?? false,
                                  stage: _coachStage,
                                  error: _coachError,
                                  blockedReason: services.coach.blockedReason,
                                  onAnalyze: () => _runCoach(),
                                  onOpenSettings: () async {
                                    await Navigator.of(context).push(
                                      MaterialPageRoute(builder: (_) => const SettingsScreen()),
                                    );
                                    if (mounted) setState(() {});
                                  },
                                ),
                            ],
                            const SizedBox(height: 12),
                            if (_engineError != null)
                              Text(_engineError!, style: const TextStyle(color: kLoss))
                            else if (analysis == null || !analysis.isComplete)
                              _AnalysisProgress(
                                done: analysis?.evals.length ?? 0,
                                total: game.positions.length,
                              ),
                            const SizedBox(height: 8),
                            if (!_awaitingGuess)
                              EvalGraph(
                                evals: [
                                  for (final e in analysis?.evals ?? const <PositionEval>[]) e.eval,
                                ],
                                plyCount: game.plyCount,
                                currentPly: _ply,
                                onSelectPly: _go,
                                markers: markers,
                                keyMoments: keyMoments,
                              ),
                          ],
                        ),
                ),
                _NavBar(
                  canBack: !_grading && (_exploring || _ply > 0),
                  canForward: !_grading && !_awaitingGuess && !_exploring && _ply < game.plyCount,
                  onStart: () => _go(0),
                  onBack: _back,
                  onForward: _forward,
                  onEnd: () => _go(game.plyCount),
                ),
                _ChatBar(
                  controller: _chatInput,
                  open: _chatOpen,
                  busy: _chatBusy,
                  enabled: services.settings.hasApiKey,
                  count: _chat?.messages.length ?? 0,
                  onToggle: () => setState(() => _chatOpen = !_chatOpen),
                  onSend: _sendChat,
                  onFocus: () {
                    if (!_chatOpen) setState(() => _chatOpen = true);
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.guessOn,
    required this.onGuessChanged,
    required this.hasKeyMoments,
    required this.onPrevKey,
    required this.onNextKey,
  });

  final bool guessOn;
  final ValueChanged<bool> onGuessChanged;
  final bool hasKeyMoments;
  final VoidCallback onPrevKey;
  final VoidCallback onNextKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          const Icon(Icons.psychology_alt_outlined, size: 20, color: kAmber),
          const SizedBox(width: 6),
          const Text('Guess the move', style: TextStyle(color: kIvory, fontSize: 14)),
          const SizedBox(width: 4),
          Switch(value: guessOn, onChanged: onGuessChanged),
          const Spacer(),
          if (hasKeyMoments) ...[
            IconButton(
              tooltip: 'Previous key moment',
              icon: const Icon(Icons.keyboard_double_arrow_left, color: kAmber),
              onPressed: onPrevKey,
            ),
            const Icon(Icons.star, size: 16, color: kAmber),
            IconButton(
              tooltip: 'Next key moment',
              icon: const Icon(Icons.keyboard_double_arrow_right, color: kAmber),
              onPressed: onNextKey,
            ),
          ],
        ],
      ),
    );
  }
}

class _GuessPrompt extends StatelessWidget {
  const _GuessPrompt({
    required this.label,
    required this.side,
    required this.grading,
    required this.onSkip,
  });

  final String label;
  final Side side;
  final bool grading;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return _Card(
      accent: kAmber,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            grading ? 'Grading your move…' : 'Your move, ${side == Side.white ? 'White' : 'Black'}',
            style: text.titleMedium?.copyWith(color: kIvory, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            grading
                ? 'Stockfish is checking it against the best move.'
                : 'What would you play at move $label? Make your move on the board.',
            style: text.bodyMedium?.copyWith(color: kIvoryMuted),
          ),
          if (grading)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: LinearProgressIndicator(minHeight: 3),
            )
          else
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onSkip, child: const Text('Skip this one')),
            ),
        ],
      ),
    );
  }
}

class _GuessCard extends StatelessWidget {
  const _GuessCard({required this.result});

  final GuessResult result;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = result.good ? kWin : kMistake;
    final same = result.guessSan.replaceAll(RegExp(r'[+#]'), '') ==
        result.playedSan.replaceAll(RegExp(r'[+#]'), '');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _Card(
        accent: color,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(result.good ? Icons.check_circle : Icons.error_outline, color: color, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'You played ${result.guessSan}${result.guessEval != null ? ' (${result.guessEval!.label})' : ''}',
                    style: text.titleSmall?.copyWith(color: kIvory, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(result.verdict, style: text.bodyMedium?.copyWith(color: color)),
            const SizedBox(height: 4),
            Text(
              [
                if (result.bestSan != null)
                  'Best: ${result.bestSan}${result.bestEval != null ? ' (${result.bestEval!.label})' : ''}',
                same ? 'Same as the game move.' : 'Game move: ${result.playedSan}',
              ].join('  ·  '),
              style: text.bodySmall?.copyWith(color: kIvoryMuted),
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
          const SizedBox(height: 4),
          Text(
            'Ask the Professor about this line in the chat below.',
            style: text.bodySmall?.copyWith(color: kIvoryMuted),
          ),
        ],
      );
    }

    final quality = analysis?.qualityOf(ply);
    final eval = analysis?.evalAt(ply);
    final bestBefore = ply > 0 ? analysis?.bestSanAt(ply - 1) : null;
    final showBest = quality != null &&
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
            if (quality != null && ply > 0) _QualityChip(quality: quality),
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

class _CoachPanel extends StatelessWidget {
  const _CoachPanel({
    required this.game,
    required this.ply,
    required this.review,
    required this.analysisComplete,
    required this.stage,
    required this.error,
    required this.blockedReason,
    required this.onAnalyze,
    required this.onOpenSettings,
  });

  final GameRecord game;
  final int ply;
  final CoachReview? review;
  final bool analysisComplete;
  final ReviewStage? stage;
  final String? error;
  final String? blockedReason;
  final VoidCallback onAnalyze;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = review;

    if (stage != null) {
      final label = switch (stage!) {
        ReviewStage.preparing => 'Getting the game ready…',
        ReviewStage.openings => 'Checking the opening against master games…',
        ReviewStage.endgames => 'Checking the endgame tablebase…',
        ReviewStage.writing => 'The Professor is writing the review. This takes about a minute…',
        ReviewStage.checking => 'Checking every comment against the game…',
        ReviewStage.done => 'Done.',
      };
      return _Card(
        accent: kAmber,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: text.bodyMedium?.copyWith(color: kIvory)),
            const SizedBox(height: 10),
            const LinearProgressIndicator(minHeight: 3),
          ],
        ),
      );
    }

    if (r == null) {
      final blocked = blockedReason;
      final waiting = !analysisComplete;
      return _Card(
        accent: kAmber,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Ask the Professor to review this game: a story of the game, a comment and arrows '
              'for every move, key moments, and lessons at the end.',
              style: text.bodyMedium?.copyWith(color: kIvoryMuted),
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error!, style: text.bodyMedium?.copyWith(color: kLoss)),
            ],
            if (blocked != null) ...[
              const SizedBox(height: 8),
              Text(blocked, style: text.bodySmall?.copyWith(color: kIvoryMuted)),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: blocked != null
                  ? (services.settings.hasApiKey ? null : onOpenSettings)
                  : (waiting ? null : onAnalyze),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              icon: Icon(blocked != null && !services.settings.hasApiKey ? Icons.key : Icons.school_outlined),
              label: Text(
                blocked != null && !services.settings.hasApiKey
                    ? 'Add API key in Settings'
                    : waiting
                    ? 'Analyze with Coach (after Stockfish finishes)'
                    : error != null
                    ? 'Try again'
                    : 'Analyze with Coach',
              ),
            ),
          ],
        ),
      );
    }

    final children = <Widget>[];
    if (ply == 0) {
      children.add(
        _Card(
          accent: kAmber,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CardTitle(icon: Icons.menu_book_outlined, title: 'The story of the game'),
              const SizedBox(height: 6),
              Text(r.summary, style: text.bodyMedium?.copyWith(color: kIvory, height: 1.4)),
              if (r.openingName != null || r.openingIdeas != null) ...[
                const SizedBox(height: 12),
                Text(
                  r.openingName ?? 'The opening',
                  style: text.titleSmall?.copyWith(color: kAmber),
                ),
                if (r.leftTheoryAtPly != null && r.leftTheoryAtPly! <= game.plyCount)
                  Text(
                    'Left master theory at ${game.moveLabel(r.leftTheoryAtPly!)}',
                    style: text.bodySmall?.copyWith(color: kIvoryMuted),
                  ),
                if (r.openingIdeas != null) ...[
                  const SizedBox(height: 4),
                  Text(r.openingIdeas!, style: text.bodyMedium?.copyWith(color: kIvory, height: 1.4)),
                ],
              ],
              const SizedBox(height: 8),
              Text(
                'Step through the moves to see the Professor\'s notes.',
                style: text.bodySmall?.copyWith(color: kIvoryMuted),
              ),
            ],
          ),
        ),
      );
    } else {
      final c = r.moves[ply];
      children.add(
        _Card(
          accent: r.keyMoments.contains(ply) ? kAmber : Colors.white24,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.school_outlined, size: 18, color: kAmber),
                  const SizedBox(width: 6),
                  Text(
                    r.keyMoments.contains(ply) ? 'The Professor · key moment' : 'The Professor',
                    style: text.labelLarge?.copyWith(color: kAmber),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                c?.comment ?? 'No note for this move.',
                style: text.bodyMedium?.copyWith(
                  color: c == null ? kIvoryMuted : kIvory,
                  height: 1.4,
                ),
              ),
              if (c != null && c.themes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in c.themes)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white10,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(t, style: const TextStyle(color: kIvoryMuted, fontSize: 12)),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    }
    if (ply == game.plyCount && (r.recapText.isNotEmpty || r.lessons.isNotEmpty)) {
      children
        ..add(const SizedBox(height: 12))
        ..add(
          _Card(
            accent: kWin,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CardTitle(icon: Icons.flag_outlined, title: 'Recap'),
                const SizedBox(height: 6),
                Text(r.recapText, style: text.bodyMedium?.copyWith(color: kIvory, height: 1.4)),
                if (r.lessons.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text('Lessons', style: text.titleSmall?.copyWith(color: kAmber)),
                  const SizedBox(height: 4),
                  for (final l in r.lessons)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            margin: const EdgeInsets.only(top: 2, right: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: kAmber.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              l.area,
                              style: const TextStyle(color: kAmber, fontSize: 11),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              l.lesson,
                              style: text.bodyMedium?.copyWith(color: kIvory, height: 1.35),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                const SizedBox(height: 8),
                Text(
                  'Reviewed by ${r.model} · ${formatDollars(r.cost)}',
                  style: text.bodySmall?.copyWith(color: kIvoryMuted),
                ),
              ],
            ),
          ),
        );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

class _CardTitle extends StatelessWidget {
  const _CardTitle({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: kAmber),
        const SizedBox(width: 6),
        Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: kIvory,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, required this.accent});

  final Widget child;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kInkRaised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: child,
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
            iconSize: 28,
            icon: const Icon(Icons.first_page),
            onPressed: canBack ? onStart : null,
          ),
          IconButton(
            tooltip: 'Previous move',
            iconSize: 36,
            icon: const Icon(Icons.chevron_left),
            onPressed: canBack ? onBack : null,
          ),
          IconButton(
            tooltip: 'Next move',
            iconSize: 36,
            icon: const Icon(Icons.chevron_right),
            onPressed: canForward ? onForward : null,
          ),
          IconButton(
            tooltip: 'End',
            iconSize: 28,
            icon: const Icon(Icons.last_page),
            onPressed: canForward ? onEnd : null,
          ),
        ],
      ),
    );
  }
}

class _ChatBar extends StatelessWidget {
  const _ChatBar({
    required this.controller,
    required this.open,
    required this.busy,
    required this.enabled,
    required this.count,
    required this.onToggle,
    required this.onSend,
    required this.onFocus,
  });

  final TextEditingController controller;
  final bool open;
  final bool busy;
  final bool enabled;
  final int count;
  final VoidCallback onToggle;
  final VoidCallback onSend;
  final VoidCallback onFocus;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: const BoxDecoration(
        color: kInkRaised,
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: open ? 'Hide chat' : 'Show chat',
            onPressed: onToggle,
            icon: Badge(
              isLabelVisible: !open && count > 0,
              label: Text('${count ~/ 2}'),
              child: Icon(open ? Icons.expand_more : Icons.forum_outlined, color: kAmber),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled && !busy,
              minLines: 1,
              maxLines: 3,
              textInputAction: TextInputAction.send,
              onTap: onFocus,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(
                isDense: true,
                hintText: enabled ? 'Ask the Professor about this position…' : 'Add an API key in Settings to chat',
                fillColor: kInk,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Send',
            onPressed: enabled && !busy ? onSend : null,
            icon: busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send, color: kAmber),
          ),
        ],
      ),
    );
  }
}

class _ChatHistory extends StatelessWidget {
  const _ChatHistory({
    required this.messages,
    required this.busy,
    required this.status,
    required this.error,
    required this.controller,
  });

  final List<ChatMessage> messages;
  final bool busy;
  final String? status;
  final String? error;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty && !busy && error == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Ask anything about the position on the board: "What if I had played Nf3 here?", '
            '"Why is this a blunder?", "What do masters play here?". The Professor checks '
            'with Stockfish on your phone and Lichess before answering.',
            textAlign: TextAlign.center,
            style: TextStyle(color: kIvoryMuted, height: 1.4),
          ),
        ),
      );
    }
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      children: [
        for (final m in messages) _Bubble(message: m),
        if (busy)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Text(status ?? 'Thinking…', style: const TextStyle(color: kIvoryMuted)),
              ],
            ),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(error!, style: const TextStyle(color: kLoss)),
          ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final user = message.fromUser;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        decoration: BoxDecoration(
          color: user ? kAmber.withValues(alpha: 0.18) : kInkRaised,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              message.text,
              style: const TextStyle(color: kIvory, height: 1.4, fontSize: 14.5),
            ),
            if (!user && message.sources.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Sources: ${message.sources.join(' · ')}',
                style: const TextStyle(color: kIvoryMuted, fontSize: 11.5),
              ),
            ],
          ],
        ),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
