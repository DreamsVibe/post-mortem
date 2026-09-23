import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../engine/engine_hub.dart';
import '../engine/game_analysis.dart';
import '../engine/stockfish_engine.dart';
import '../game_record.dart';
import '../storage.dart';
import 'claude_client.dart';
import 'narration.dart';

enum QueueState { queued, engine, coach, done, failed }

/// One game waiting for, or going through, a full coach review.
class QueueItem {
  QueueItem({
    required this.key,
    required this.game,
    required this.addedAt,
    this.state = QueueState.queued,
    this.error,
  });

  final String key;
  final GameRecord game;
  final DateTime addedAt;
  QueueState state;
  String? error;

  /// Positions analyzed so far (engine stage).
  int enginePositions = 0;
  ReviewStage? stage;
  DateTime? finishedAt;

  bool get active => state == QueueState.engine || state == QueueState.coach;
  bool get pending => state == QueueState.queued || active;

  String get statusText => switch (state) {
    QueueState.queued => 'Waiting in the queue',
    QueueState.engine => 'Stockfish: $enginePositions / ${game.positions.length} positions',
    QueueState.coach => switch (stage) {
      ReviewStage.openings => 'Checking the opening against master games',
      ReviewStage.endgames => 'Checking the endgame tablebase',
      ReviewStage.writing => 'The Professor is writing the review',
      ReviewStage.checking => 'Checking every note against the game',
      _ => 'Preparing the review',
    },
    QueueState.done => 'Review ready',
    QueueState.failed => error ?? 'Failed',
  };

  /// Rough progress from 0 to 1 for a progress bar.
  double get progress => switch (state) {
    QueueState.queued => 0,
    QueueState.engine => 0.5 * enginePositions / game.positions.length,
    QueueState.coach => switch (stage) {
      ReviewStage.writing => 0.7,
      ReviewStage.checking => 0.92,
      _ => 0.55,
    },
    QueueState.done => 1,
    QueueState.failed => 0,
  };

  Map<String, dynamic> toJson() => {
    'key': key,
    'game': game.toJson(),
    'addedAt': addedAt.toIso8601String(),
    'state': state.name,
    'error': error,
    'finishedAt': finishedAt?.toIso8601String(),
  };

  static QueueItem? fromJson(Map<String, dynamic> j) {
    final game = GameRecord.fromJson((j['game'] as Map).cast());
    if (game == null) return null;
    var state = QueueState.values.firstWhere(
      (s) => s.name == j['state'],
      orElse: () => QueueState.queued,
    );
    // Work that was in progress when the app closed starts again from the queue.
    if (state == QueueState.engine || state == QueueState.coach) state = QueueState.queued;
    return QueueItem(
      key: j['key'] as String,
      game: game,
      addedAt: DateTime.tryParse(j['addedAt'] as String? ?? '') ?? DateTime.now(),
      state: state,
      error: j['error'] as String?,
    )..finishedAt = DateTime.tryParse(j['finishedAt'] as String? ?? '');
  }
}

/// Runs coach reviews one game at a time in the background.
///
/// The queue lives for the whole app session, so leaving a game or looking at other games never
/// stops it. While it has work, an Android foreground service keeps the app alive in the
/// background (with a notification). The queue is saved to the phone, so if the app is closed
/// completely it picks up where it left off the next time the app opens.
class AnalysisQueue extends ChangeNotifier {
  AnalysisQueue({required this.hub, required this.coach, required this.store});

  final EngineHub hub;
  final CoachService coach;
  final LocalStore store;

  static const _channel = MethodChannel('post_mortem/background');
  static const _keepDone = 25;

  final List<QueueItem> _items = [];
  final Set<String> _reviewed = {};
  bool _running = false;
  bool _serviceOn = false;

  List<QueueItem> get items => List.unmodifiable(_items);
  int get pendingCount => _items.where((i) => i.pending).length;

  /// Keys of games that have a saved coach review.
  Set<String> get reviewed => _reviewed;

  QueueItem? itemFor(GameRecord game) {
    final key = gameKey(game);
    return _items.where((i) => i.key == key).firstOrNull;
  }

  Future<void> load() async {
    _reviewed.addAll(await store.keys('coach'));
    final j = await store.read('queue', 'items');
    for (final raw in (j?['items'] as List? ?? const [])) {
      try {
        final item = QueueItem.fromJson((raw as Map).cast());
        if (item != null) _items.add(item);
      } catch (_) {}
    }
    notifyListeners();
    _pump();
  }

  /// Adds [game] to the queue (no-op if it's already waiting or running).
  Future<void> add(GameRecord game) async {
    final existing = itemFor(game);
    if (existing != null && existing.pending) return;
    if (existing != null) _items.remove(existing);
    _items.add(QueueItem(key: gameKey(game), game: game, addedAt: DateTime.now()));
    await _save();
    notifyListeners();
    _pump();
  }

  /// Removes a waiting, finished or failed item. Running items can't be removed.
  Future<void> remove(QueueItem item) async {
    if (item.active) return;
    _items.remove(item);
    await _save();
    notifyListeners();
  }

  Future<void> retry(QueueItem item) async {
    if (item.state != QueueState.failed) return;
    item
      ..state = QueueState.queued
      ..error = null;
    await _save();
    notifyListeners();
    _pump();
  }

  Future<void> clearFinished() async {
    _items.removeWhere((i) => i.state == QueueState.done || i.state == QueueState.failed);
    await _save();
    notifyListeners();
  }

  /// Called after coach data is wiped from Settings.
  Future<void> forgetReviews() async {
    _reviewed.clear();
    _items.removeWhere((i) => i.state == QueueState.done);
    await _save();
    notifyListeners();
  }

  void markReviewed(GameRecord game) {
    _reviewed.add(gameKey(game));
    notifyListeners();
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final next = _items.where((i) => i.state == QueueState.queued).firstOrNull;
        if (next == null) break;
        await _startService();
        await _process(next);
      }
    } finally {
      _running = false;
      await _stopService();
    }
  }

  Future<void> _process(QueueItem item) async {
    final blocked = coach.blockedReason;
    if (blocked != null) {
      item
        ..state = QueueState.failed
        ..error = blocked;
      await _save();
      notifyListeners();
      return;
    }
    try {
      item
        ..state = QueueState.engine
        ..enginePositions = 0;
      notifyListeners();
      _notify(item);
      final GameAnalysis analysis = await hub.complete(
        item.game,
        onProgress: (a) {
          item.enginePositions = a.evals.length;
          notifyListeners();
          if (a.evals.length % 10 == 0) _notify(item);
        },
      );
      item
        ..state = QueueState.coach
        ..stage = ReviewStage.preparing;
      notifyListeners();
      _notify(item);
      await coach.review(
        item.game,
        analysis,
        onStage: (s) {
          item.stage = s;
          notifyListeners();
          _notify(item);
        },
      );
      item
        ..state = QueueState.done
        ..finishedAt = DateTime.now();
      _reviewed.add(item.key);
    } on ClaudeException catch (e) {
      item
        ..state = QueueState.failed
        ..error = e.message;
    } on EngineException catch (e) {
      item
        ..state = QueueState.failed
        ..error = e.message;
    } catch (e) {
      item
        ..state = QueueState.failed
        ..error = 'Something went wrong: $e';
    }
    // Keep the list short: drop the oldest finished items.
    final finished = _items.where((i) => i.state == QueueState.done).toList();
    if (finished.length > _keepDone) {
      for (final old in finished.take(finished.length - _keepDone)) {
        _items.remove(old);
      }
    }
    await _save();
    notifyListeners();
  }

  String _gameLabel(GameRecord g) => '${g.white.name} vs ${g.black.name}';

  void _notify(QueueItem item) {
    if (!_serviceOn) return;
    final waiting = _items.where((i) => i.state == QueueState.queued).length;
    final text = '${_gameLabel(item.game)}: ${item.statusText}'
        '${waiting > 0 ? ' · $waiting more waiting' : ''}';
    _channel.invokeMethod<bool>('update', {'text': text}).catchError((_) => false);
  }

  Future<void> _startService() async {
    if (_serviceOn) return;
    try {
      _serviceOn = await _channel.invokeMethod<bool>('start', {'text': 'Analyzing games…'}) ?? false;
    } catch (_) {
      _serviceOn = false;
    }
  }

  Future<void> _stopService() async {
    if (!_serviceOn) return;
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (_) {}
    _serviceOn = false;
  }

  Future<void> _save() async {
    try {
      await store.write('queue', 'items', {
        'items': [for (final i in _items) i.toJson()],
      });
    } catch (e) {
      debugPrint('Could not save the queue: $e');
    }
  }
}
