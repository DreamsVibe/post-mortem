import 'dart:async';
import 'dart:io';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:multistockfish/multistockfish.dart';

import 'eval.dart';

/// Thrown when Stockfish could not be started or stopped responding.
class EngineException implements Exception {
  const EngineException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The single on-device Stockfish (16, embedded NNUE) shared by the whole app.
///
/// Searches run one at a time through a queue, so the full-game analysis, Guess the move and the
/// coach chat's engine tool can all use it without talking over each other. Interactive requests
/// jump ahead of queued background work.
class StockfishEngine {
  StockfishEngine._();

  static final StockfishEngine instance = StockfishEngine._();

  final Stockfish _sf = Stockfish.instance;
  StreamSubscription<String>? _sub;
  Future<void>? _starting;
  bool _ready = false;

  final _waiters = <_LineWaiter>[];

  // Simple two-level queue: interactive work first, then background work.
  final _interactive = <Completer<void>>[];
  final _background = <Completer<void>>[];
  bool _busy = false;

  Future<void> ensureStarted() {
    if (_ready) return Future.value();
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<void> _start() async {
    if (_sf.state.value != StockfishState.ready) {
      if (_sf.state.value == StockfishState.error) {
        try {
          await _sf.quit();
        } catch (_) {}
      }
      if (_sf.state.value != StockfishState.starting) {
        await _sf.start();
      }
      await _waitForState(StockfishState.ready);
    }
    _sub ??= _sf.stdout.listen(_onLine);
    _send('uci');
    await _waitFor((l) => l.trim() == 'uciok', const Duration(seconds: 10));
    final threads = (Platform.numberOfProcessors - 1).clamp(1, 4);
    _send('setoption name Threads value $threads');
    _send('setoption name Hash value 64');
    _send('setoption name UCI_AnalyseMode value true');
    _send('isready');
    await _waitFor((l) => l.trim() == 'readyok', const Duration(seconds: 10));
    _ready = true;
  }

  Future<void> _waitForState(StockfishState target) async {
    if (_sf.state.value == target) return;
    final done = Completer<void>();
    void listener() {
      final s = _sf.state.value;
      if (s == target && !done.isCompleted) done.complete();
      if (s == StockfishState.error && !done.isCompleted) {
        done.completeError(const EngineException('Stockfish failed to start on this phone.'));
      }
    }

    _sf.state.addListener(listener);
    try {
      listener();
      await done.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw const EngineException('Stockfish took too long to start.'),
      );
    } finally {
      _sf.state.removeListener(listener);
    }
  }

  void _send(String cmd) => _sf.stdin = cmd;

  void _onLine(String line) {
    for (final w in List.of(_waiters)) {
      w.onLine(line);
    }
  }

  Future<String> _waitFor(bool Function(String) test, Duration timeout) {
    final w = _LineWaiter(test);
    _waiters.add(w);
    return w.completer.future.timeout(timeout, onTimeout: () {
      throw const EngineException('Stockfish stopped responding.');
    }).whenComplete(() => _waiters.remove(w));
  }

  Future<void> _acquire({required bool interactive}) {
    if (!_busy) {
      _busy = true;
      return Future.value();
    }
    final c = Completer<void>();
    (interactive ? _interactive : _background).add(c);
    return c.future;
  }

  void _release() {
    if (_interactive.isNotEmpty) {
      _interactive.removeAt(0).complete();
    } else if (_background.isNotEmpty) {
      _background.removeAt(0).complete();
    } else {
      _busy = false;
    }
  }

  /// Analyzes [fen] and returns up to [multiPv] lines, best first, evals from White's view.
  ///
  /// The search stops at [depth] or after [movetime], whichever comes first.
  Future<List<EngineLine>> analyze(
    String fen, {
    int depth = 16,
    Duration movetime = const Duration(milliseconds: 1500),
    int multiPv = 1,
    bool interactive = false,
  }) async {
    await ensureStarted();
    await _acquire(interactive: interactive);
    try {
      final whiteToMove = fen.split(' ').elementAtOrNull(1) != 'b';
      final lines = <int, EngineLine>{};
      final info = _LineWaiter((l) => l.startsWith('bestmove'));
      info.onOther = (l) {
        final parsed = _parseInfo(l, whiteToMove);
        if (parsed != null) lines[parsed.$1] = parsed.$2;
      };
      _waiters.add(info);
      try {
        _send('setoption name MultiPV value $multiPv');
        _send('position fen $fen');
        _send('go depth $depth movetime ${movetime.inMilliseconds}');
        await info.completer.future.timeout(
          movetime + const Duration(seconds: 10),
          onTimeout: () {
            _send('stop');
            throw const EngineException('Stockfish stopped responding.');
          },
        );
      } finally {
        _waiters.remove(info);
      }
      final result = [
        for (var i = 1; i <= multiPv; i++)
          if (lines[i] != null) lines[i]!,
      ];
      if (result.isEmpty) {
        // No legal moves: mate or stalemate. Report a terminal eval.
        final bm = await _terminalEval(fen, whiteToMove);
        return [bm];
      }
      return result;
    } finally {
      _release();
    }
  }

  Future<EngineLine> _terminalEval(String fen, bool whiteToMove) async {
    // No legal moves: checkmate (the side to move lost) or stalemate (a draw).
    try {
      final pos = Chess.fromSetup(Setup.parseFen(fen));
      if (pos.isCheckmate) {
        return EngineLine(eval: Eval.checkmate(whiteWon: !whiteToMove), pv: const [], depth: 0);
      }
    } catch (_) {}
    return const EngineLine(eval: Eval.cp(0), pv: [], depth: 0);
  }

  /// Parses an "info ... multipv N score ... pv ..." line into (multipv, line).
  (int, EngineLine)? _parseInfo(String line, bool whiteToMove) {
    if (!line.startsWith('info ') || !line.contains(' pv ') || !line.contains(' score ')) {
      return null;
    }
    if (line.contains('lowerbound') || line.contains('upperbound')) return null;
    final parts = line.split(' ');
    int? depth, multipv, cp, mate;
    List<String> pv = const [];
    for (var i = 0; i < parts.length; i++) {
      switch (parts[i]) {
        case 'depth':
          depth = int.tryParse(parts.elementAtOrNull(i + 1) ?? '');
        case 'multipv':
          multipv = int.tryParse(parts.elementAtOrNull(i + 1) ?? '');
        case 'score':
          final kind = parts.elementAtOrNull(i + 1);
          final v = int.tryParse(parts.elementAtOrNull(i + 2) ?? '');
          if (kind == 'cp') cp = v;
          if (kind == 'mate') mate = v;
        case 'pv':
          pv = parts.sublist(i + 1).where((m) => m.isNotEmpty).toList();
          i = parts.length;
      }
    }
    if (depth == null || (cp == null && mate == null)) return null;
    final sign = whiteToMove ? 1 : -1;
    final eval = mate != null ? Eval.mate(mate * sign) : Eval.cp(cp! * sign);
    return (multipv ?? 1, EngineLine(eval: eval, pv: pv, depth: depth));
  }

  @visibleForTesting
  (int, EngineLine)? parseInfoForTest(String line, bool whiteToMove) =>
      _parseInfo(line, whiteToMove);
}

class _LineWaiter {
  _LineWaiter(this.test);

  final bool Function(String) test;
  final completer = Completer<String>();
  void Function(String)? onOther;

  void onLine(String line) {
    if (completer.isCompleted) return;
    if (test(line)) {
      completer.complete(line);
    } else {
      onOther?.call(line);
    }
  }
}
