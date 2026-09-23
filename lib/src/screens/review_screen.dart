import 'dart:async';

import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../coach/analysis_queue.dart';
import '../coach/chat.dart';
import '../coach/claude_client.dart';
import '../coach/coach_models.dart';
import '../coach/pgn_export.dart';
import '../engine/eval.dart';
import '../engine/game_analysis.dart';
import '../engine/stockfish_engine.dart';
import '../game_record.dart';
import '../lichess_client.dart';
import '../services.dart';
import '../storage.dart';
import '../theme.dart';
import '../widgets/eval_graph.dart';
import 'queue_screen.dart';
import 'review_widgets.dart';
import 'settings_screen.dart';

export 'review_widgets.dart' show qualityColor, kInaccuracy, kMistake, kBlunder;

/// The review screen: players on top, eval strip, board and graph, and a pull-up sheet with the
/// Professor's notes and the coach chat.
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

  // Engine analysis, shared with the queue through the hub.
  late final ValueListenable<GameAnalysis?> _analysisSource = services.hub.hold(game);
  GameAnalysis? _analysis;
  String? _engineError;

  // Exploration away from the game's moves.
  int? _branchPly;
  final List<VariationMove> _variation = [];
  PositionEval? _liveEval;
  int _liveToken = 0;

  // Coach review.
  CoachReview? _review;
  bool _showArrows = true;

  // Guess the move.
  bool _guessOn = false;
  bool _awaitingGuess = false;
  bool _grading = false;
  GuessResult? _guess;

  // Sheet and chat.
  final _sheet = DraggableScrollableController();
  ScrollController? _sheetScroll;
  double _sheetSize = 0;
  double _minSheet = 0.3;
  bool _chatTab = false;
  ChatSession? _chat;
  bool _chatBusy = false;
  String? _chatStatus;
  String? _chatError;
  final _chatInput = TextEditingController();
  final _chatFocus = FocusNode();

  late final ChessboardController _board = ChessboardController(game: _gameData());

  Side? get _userSide => game.sideOf(services.settings.username);

  @override
  void initState() {
    super.initState();
    _analysis = _analysisSource.value;
    _analysisSource.addListener(_onAnalysis);
    services.queue.addListener(_onQueue);
    _sheet.addListener(_onSheet);
    _chatFocus.addListener(() {
      if (_chatFocus.hasFocus) _expandSheet();
    });
    _loadCoach();
  }

  @override
  void dispose() {
    _analysisSource.removeListener(_onAnalysis);
    services.hub.release(game);
    services.queue.removeListener(_onQueue);
    _sheet.removeListener(_onSheet);
    _sheet.dispose();
    _board.dispose();
    _chatInput.dispose();
    _chatFocus.dispose();
    super.dispose();
  }

  void _onAnalysis() {
    if (!mounted) return;
    setState(() {
      _analysis = _analysisSource.value;
      _engineError = services.hub.errorOf(game);
    });
  }

  void _onQueue() {
    if (!mounted) return;
    final item = services.queue.itemFor(game);
    if (item?.state == QueueState.done && _review == null) {
      _loadCoach();
    } else {
      setState(() {});
    }
  }

  void _onSheet() {
    if (!_sheet.isAttached) return;
    final s = _sheet.size;
    if ((s - _sheetSize).abs() <= 0.002) return;
    // The sheet can report its size during layout; never rebuild in the middle of a frame.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _sheetSize = s);
      });
    } else {
      setState(() => _sheetSize = s);
    }
  }

  Future<void> _loadCoach() async {
    final review = await services.coach.cached(game);
    final chat = _chat ?? await ChatSession.load(game, services.store);
    if (!mounted) return;
    setState(() {
      _review = review;
      _chat = chat;
    });
    if (review != null) services.queue.markReviewed(game);
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

  void _resetNotesScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _sheetScroll;
      if (!_chatTab && c != null && c.hasClients) c.jumpTo(0);
    });
  }

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
    _resetNotesScroll();
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
        _chatTab = false;
      });
      _resetNotesScroll();
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

  Future<void> _queueReview() async {
    final blocked = services.coach.blockedReason;
    if (blocked != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(blocked)));
      return;
    }
    await services.queue.add(game);
  }

  Future<void> _redoReview() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Redo the review?'),
        content: const Text(
          'The Professor will write a fresh review of this game in the queue. It costs about as '
          'much as the first one.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Redo')),
        ],
      ),
    );
    if (ok != true) return;
    await services.coach.deleteReview(game);
    services.queue.reviewed.remove(gameKey(game));
    setState(() => _review = null);
    await _queueReview();
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
        const SnackBar(content: Text('Analyze with Coach first, then export the review.')),
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
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
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
    final date = game.playedAt?.toLocal().toString().substring(0, 10);
    final name = side == null
        ? '${game.white.name} vs ${game.black.name}'
        : 'vs ${game.opponentOf(side).name}${date != null ? ' $date' : ''}';
    try {
      final url = await services.lichess.importToStudy(
        picked.$1,
        annotatedPgn(game, review),
        name,
        token,
      );
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

  // ---- Sheet and chat ----

  void _expandSheet() {
    if (_sheet.isAttached) {
      _sheet.animateTo(0.9, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    }
  }

  void _selectTab(bool chat) {
    setState(() => _chatTab = chat);
    if (chat) _scrollChatToEnd();
  }

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
    _chatInput.clear();
    setState(() {
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
      final c = _sheetScroll;
      if (_chatTab && c != null && c.hasClients) {
        c.animateTo(
          c.position.maxScrollExtent,
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

  void _showMoveList(Map<int, Color> colors, Set<int> keyMoments) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kInk,
      isScrollControlled: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
      builder: (context) => MoveListSheet(
        game: game,
        currentPly: _ply,
        colors: colors,
        keyMoments: keyMoments,
        onSelect: (p) {
          Navigator.pop(context);
          _go(p);
        },
      ),
    );
  }

  // ---- UI ----

  Eval? get _shownEval => _exploring ? _liveEval?.eval : _analysis?.evalAt(_ply);

  (String, Color?) get _stripLabel {
    if (_awaitingGuess) return ('Your move…', kAmber);
    if (_exploring) return ('Side line', kAmber);
    if (_ply == 0) return ('Start', null);
    final q = _analysis?.qualityOf(_ply);
    if (q == null) return (game.moveLabel(_ply), null);
    return ('${game.moveLabel(_ply)} · ${q.label}', qualityColor(q) ?? (q == MoveQuality.best ? kWin : null));
  }

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
    final (label, labelColor) = _stripLabel;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        toolbarHeight: 60,
        title: PlayersHeader(left: top, right: bottom),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'flip':
                  setState(() => _orientation = _orientation.opposite);
                case 'arrows':
                  setState(() => _showArrows = !_showArrows);
                case 'export':
                  _export();
                case 'redo':
                  _redoReview();
                case 'clearchat':
                  _clearChat();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'flip', child: Text('Flip board')),
              if (review != null)
                PopupMenuItem(
                  value: 'arrows',
                  child: Text(_showArrows ? 'Hide coach arrows' : 'Show coach arrows'),
                ),
              const PopupMenuItem(value: 'export', child: Text('Export to Lichess study')),
              if (review != null && !(services.queue.itemFor(game)?.pending ?? false))
                const PopupMenuItem(value: 'redo', child: Text('Redo coach review')),
              if (_chat?.messages.isNotEmpty ?? false)
                const PopupMenuItem(value: 'clearchat', child: Text('Clear chat')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final h = constraints.maxHeight;
                  final w = constraints.maxWidth;
                  const pad = 12.0;
                  const stripH = 30.0;
                  const graphH = 44.0;
                  const gaps = 6.0 * 3;
                  final fullBoard = w - pad * 2;
                  // The sheet rests just under the graph; never smaller than a few lines of text.
                  final restPx = (h - (stripH + fullBoard + graphH + gaps)).clamp(170.0, h * 0.6);
                  final minSize = (restPx / h).clamp(0.2, 0.6);
                  _minSheet = minSize;
                  final size = _sheetSize == 0 ? minSize : _sheetSize.clamp(minSize, 0.9);
                  // As the sheet rises, the board shrinks to stay visible above it.
                  final topSpace = h * (1 - size);
                  final showGraph = topSpace - stripH - gaps - 140 > graphH + 60;
                  final boardSize = (topSpace - stripH - gaps - (showGraph ? graphH : 0))
                      .clamp(120.0, fullBoard);
                  return Stack(
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(pad, 6, pad, 6),
                              child: EvalStrip(
                                eval: _awaitingGuess ? null : _shownEval,
                                label: label,
                                labelColor: labelColor,
                                orientation: _orientation,
                              ),
                            ),
                            Chessboard(
                              size: boardSize,
                              controller: _board,
                              orientation: _orientation,
                              onMove: _grading ? null : _onBoardMove,
                              shapes: _shapes,
                              settings: ChessboardSettings(
                                enablePremoves: false,
                                borderRadius: BorderRadius.circular(6),
                                animationDuration: const Duration(milliseconds: 180),
                              ),
                            ),
                            if (showGraph && !_awaitingGuess)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(pad, 6, pad, 0),
                                child: SizedBox(
                                  height: graphH,
                                  child: EvalGraph(
                                    evals: [
                                      for (final e in analysis?.evals ?? const <PositionEval>[])
                                        e.eval,
                                    ],
                                    plyCount: game.plyCount,
                                    currentPly: _ply,
                                    onSelectPly: _go,
                                    markers: markers,
                                    keyMoments: keyMoments,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      DraggableScrollableSheet(
                        controller: _sheet,
                        initialChildSize: minSize,
                        minChildSize: minSize,
                        maxChildSize: 0.9,
                        snap: true,
                        snapSizes: [if (0.6 > minSize + 0.05) 0.6],
                        builder: (context, scroll) {
                          _sheetScroll = scroll;
                          return _buildSheet(scroll, h, analysis, review, keyMoments);
                        },
                      ),
                    ],
                  );
                },
              ),
            ),
            ReviewControls(
              guessOn: _guessOn,
              onToggleGuess: () => setState(() {
                _guessOn = !_guessOn;
                if (!_guessOn) _awaitingGuess = false;
                _guess = null;
                if (_guessOn) _chatTab = false;
              }),
              hasKeyMoments: keyMoments.isNotEmpty,
              onPrevKey: () => _jumpKeyMoment(false),
              onNextKey: () => _jumpKeyMoment(true),
              onMoveList: () => _showMoveList(colors, keyMoments),
              canBack: !_grading && (_exploring || _ply > 0),
              canForward: !_grading && !_awaitingGuess && !_exploring && _ply < game.plyCount,
              onBack: _back,
              onForward: _forward,
              onStart: () => _go(0),
              onEnd: () => _go(game.plyCount),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSheet(
    ScrollController scroll,
    double h,
    GameAnalysis? analysis,
    CoachReview? review,
    Set<int> keyMoments,
  ) {
    final header = SheetHeader(
      chatTab: _chatTab,
      onTab: _selectTab,
      chatCount: (_chat?.messages.length ?? 0) ~/ 2,
      onDrag: (dy) {
        if (!_sheet.isAttached) return;
        _sheet.jumpTo((_sheet.size - dy / h).clamp(_minSheet, 0.9));
      },
      onDragEnd: () {},
    );

    final Widget content;
    if (_chatTab) {
      content = Column(
        children: [
          Expanded(
            child: ChatHistory(
              messages: _chat?.messages ?? const [],
              busy: _chatBusy,
              status: _chatStatus,
              error: _chatError,
              controller: scroll,
            ),
          ),
          ChatInput(
            controller: _chatInput,
            focusNode: _chatFocus,
            busy: _chatBusy,
            enabled: services.settings.hasApiKey,
            onSend: _sendChat,
          ),
        ],
      );
    } else {
      content = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v < -250 && !_awaitingGuess) _forward();
          if (v > 250) _back();
        },
        child: ListView(
          key: ValueKey('notes-$_ply-${_exploring ? 'x' : ''}'),
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: _notesChildren(analysis, review, keyMoments),
        ),
      );
    }

    return Material(
      color: kInkRaised,
      elevation: 8,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [header, Expanded(child: content)]),
    );
  }

  List<Widget> _notesChildren(GameAnalysis? analysis, CoachReview? review, Set<int> keyMoments) {
    final out = <Widget>[];
    if (_awaitingGuess) {
      out.add(
        GuessPrompt(
          label: game.moveLabel(_ply + 1).split(' ').first,
          side: game.positions[_ply].turn,
          grading: _grading,
          onSkip: () => _go(_ply + 1),
        ),
      );
      return out;
    }
    if (_guess != null && _guess!.ply == _ply) {
      out
        ..add(GuessCard(result: _guess!))
        ..add(const SizedBox(height: 12));
    }
    if (_exploring) {
      out.add(
        ExplorationInfo(
          game: game,
          branchPly: _branchPly ?? _ply,
          variation: _variation,
          liveEval: _liveEval,
          onBackToGame: () => _go(_branchPly ?? _ply),
        ),
      );
      return out;
    }

    out
      ..add(
        MoveHeadline(
          game: game,
          ply: _ply,
          analysis: analysis,
          isKeyMoment: keyMoments.contains(_ply),
        ),
      )
      ..add(const SizedBox(height: 12));

    if (review != null) {
      out.add(CoachNotes(game: game, ply: _ply, review: review));
    } else {
      out.add(
        CoachStatus(
          item: services.queue.itemFor(game),
          analysisComplete: analysis?.isComplete ?? false,
          blockedReason: services.coach.blockedReason,
          hasApiKey: services.settings.hasApiKey,
          onAnalyze: _queueReview,
          onRetry: () {
            final item = services.queue.itemFor(game);
            if (item != null) services.queue.retry(item);
          },
          onOpenSettings: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            );
            if (mounted) setState(() {});
          },
          onOpenQueue: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const QueueScreen()),
          ),
        ),
      );
    }

    if (_engineError != null) {
      out
        ..add(const SizedBox(height: 12))
        ..add(Text(_engineError!, style: const TextStyle(color: kLoss)));
    } else if (analysis == null || !analysis.isComplete) {
      out
        ..add(const SizedBox(height: 14))
        ..add(
          AnalysisProgress(done: analysis?.evals.length ?? 0, total: game.positions.length),
        );
    }
    return out;
  }
}
