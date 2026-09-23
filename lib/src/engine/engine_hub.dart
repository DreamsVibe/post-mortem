import 'dart:async';

import 'package:flutter/foundation.dart';

import '../game_record.dart';
import '../settings.dart';
import '../storage.dart';
import 'game_analysis.dart';
import 'stockfish_engine.dart';

/// Shares one Stockfish analysis per game between everything that wants it.
///
/// The review screen and the analysis queue both ask the hub instead of running their own
/// analysis, so a game is never analyzed twice at once. A job keeps running while anyone holds it
/// and is cancelled when the last holder lets go before it finishes.
class EngineHub {
  EngineHub(this._analyzer, this._settings);

  final GameAnalyzer _analyzer;
  final AppSettings _settings;
  final Map<String, _Job> _jobs = {};

  /// Starts (or joins) the analysis of [game] and returns a listenable of its progress. Call
  /// [release] with the same game when done watching.
  ValueListenable<GameAnalysis?> hold(GameRecord game) {
    final key = gameKey(game);
    final job = _jobs[key] ??= _Job(game)..start(_analyzer, _settings.depth, () => _jobs.remove(key));
    job.holders++;
    return job.value;
  }

  void release(GameRecord game) {
    final key = gameKey(game);
    final job = _jobs[key];
    if (job == null) return;
    job.holders--;
    if (job.holders <= 0 && !job.done.isCompleted) {
      job.cancel();
      _jobs.remove(key);
    }
  }

  /// The error of the current job for [game], if it failed.
  String? errorOf(GameRecord game) => _jobs[gameKey(game)]?.error;

  /// Analyzes [game] to completion (holding it the whole time) and returns the result.
  Future<GameAnalysis> complete(GameRecord game, {void Function(GameAnalysis)? onProgress}) async {
    final notifier = hold(game);
    final job = _jobs[gameKey(game)]!;
    void listener() {
      final v = notifier.value;
      if (v != null) onProgress?.call(v);
    }

    notifier.addListener(listener);
    try {
      return await job.done.future;
    } finally {
      notifier.removeListener(listener);
      release(game);
    }
  }
}

class _Job {
  _Job(this.game);

  final GameRecord game;
  final value = ValueNotifier<GameAnalysis?>(null);
  final done = Completer<GameAnalysis>();
  int holders = 0;
  String? error;
  StreamSubscription<GameAnalysis>? _sub;
  bool _cancelled = false;

  Future<void> start(GameAnalyzer analyzer, EngineDepth depth, VoidCallback onFinished) async {
    final cached = await analyzer.cached(game);
    if (_cancelled) return;
    if (cached != null) {
      value.value = cached;
      done.complete(cached);
      onFinished();
      return;
    }
    _sub = analyzer
        .analyze(game, depth)
        .listen(
          (a) {
            value.value = a;
            if (a.isComplete && !done.isCompleted) {
              // The analyzer writes its cache right after the final event; give it a moment.
              Future<void>.delayed(const Duration(milliseconds: 50), () {
                if (!done.isCompleted) done.complete(a);
                onFinished();
              });
            }
          },
          onError: (Object e) {
            error = e is EngineException ? e.message : 'Stockfish ran into a problem.';
            if (!done.isCompleted) done.completeError(EngineException(error!));
            onFinished();
          },
        );
  }

  void cancel() {
    _cancelled = true;
    _sub?.cancel();
    if (!done.isCompleted) {
      done.completeError(const EngineException('Analysis was stopped.'));
      done.future.ignore();
    }
  }
}
