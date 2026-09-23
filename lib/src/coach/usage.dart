import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../settings.dart';

/// One billed Claude call.
class UsageEntry {
  const UsageEntry({required this.at, required this.kind, required this.label, required this.cost});

  final DateTime at;

  /// "Review" or "Chat".
  final String kind;
  final String label;
  final double cost;

  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    'kind': kind,
    'label': label,
    'cost': cost,
  };

  static UsageEntry fromJson(Map<String, dynamic> j) => UsageEntry(
    at: DateTime.parse(j['at'] as String),
    kind: j['kind'] as String,
    label: j['label'] as String,
    cost: (j['cost'] as num).toDouble(),
  );
}

/// Token counts reported by the API for one response.
class TokenUsage {
  const TokenUsage({
    this.input = 0,
    this.output = 0,
    this.cacheWrite = 0,
    this.cacheRead = 0,
  });

  final int input;
  final int output;
  final int cacheWrite;
  final int cacheRead;

  static TokenUsage fromJson(Map<String, dynamic>? j) => TokenUsage(
    input: (j?['input_tokens'] as num?)?.toInt() ?? 0,
    output: (j?['output_tokens'] as num?)?.toInt() ?? 0,
    cacheWrite: (j?['cache_creation_input_tokens'] as num?)?.toInt() ?? 0,
    cacheRead: (j?['cache_read_input_tokens'] as num?)?.toInt() ?? 0,
  );

  TokenUsage operator +(TokenUsage o) => TokenUsage(
    input: input + o.input,
    output: output + o.output,
    cacheWrite: cacheWrite + o.cacheWrite,
    cacheRead: cacheRead + o.cacheRead,
  );

  /// Estimated cost in dollars at [model]'s list prices.
  double costFor(CoachModel model) {
    final inRate = model.inputPerMTok / 1e6;
    final outRate = model.outputPerMTok / 1e6;
    return input * inRate + cacheWrite * inRate * 1.25 + cacheRead * inRate * 0.1 + output * outRate;
  }
}

/// Keeps a running tally of what the coach has cost, per calendar month, and enforces the
/// optional monthly cap.
class UsageTracker extends ChangeNotifier {
  UsageTracker(this._prefs, this._settings) {
    _load();
  }

  static const _kLog = 'usage_log';
  static const _kMonths = 'usage_months';
  static const _maxLog = 60;

  final SharedPreferences _prefs;
  final AppSettings _settings;
  final List<UsageEntry> _log = [];
  final Map<String, double> _months = {};

  void _load() {
    try {
      final log = _prefs.getString(_kLog);
      if (log != null) {
        _log.addAll([
          for (final e in jsonDecode(log) as List) UsageEntry.fromJson((e as Map).cast()),
        ]);
      }
      final months = _prefs.getString(_kMonths);
      if (months != null) {
        (jsonDecode(months) as Map).forEach((k, v) => _months[k as String] = (v as num).toDouble());
      }
    } catch (_) {}
  }

  static String _monthKey(DateTime t) => '${t.year}-${t.month.toString().padLeft(2, '0')}';

  List<UsageEntry> get recent => List.unmodifiable(_log.reversed);

  double get thisMonth => _months[_monthKey(DateTime.now())] ?? 0;

  double get lastMonth {
    final now = DateTime.now();
    return _months[_monthKey(DateTime(now.year, now.month - 1))] ?? 0;
  }

  /// Non-null when the monthly cap has been reached, with a message to show.
  String? get capReached {
    final cap = _settings.monthlyCap;
    if (cap == null || thisMonth < cap) return null;
    return 'This month\'s coach spending (\$${thisMonth.toStringAsFixed(2)}) has reached your '
        '\$${cap.toStringAsFixed(2)} cap. Raise or remove it in Settings to keep using the coach.';
  }

  Future<void> record({required String kind, required String label, required double cost}) async {
    final now = DateTime.now();
    _log.add(UsageEntry(at: now, kind: kind, label: label, cost: cost));
    if (_log.length > _maxLog) _log.removeRange(0, _log.length - _maxLog);
    final key = _monthKey(now);
    _months[key] = (_months[key] ?? 0) + cost;
    await _prefs.setString(_kLog, jsonEncode([for (final e in _log) e.toJson()]));
    await _prefs.setString(_kMonths, jsonEncode(_months));
    notifyListeners();
  }

  Future<void> reset() async {
    _log.clear();
    _months.clear();
    await _prefs.remove(_kLog);
    await _prefs.remove(_kMonths);
    notifyListeners();
  }
}

String formatDollars(double d) {
  if (d == 0) return '\$0.00';
  if (d < 0.01) return '<\$0.01';
  return '\$${d.toStringAsFixed(2)}';
}
