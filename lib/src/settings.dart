import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine/game_analysis.dart';

/// Claude models the coach can use.
enum CoachModel {
  sonnet('claude-sonnet-5', 'Sonnet 5', 'Strong commentary at a good price', 2.0, 10.0),
  opus('claude-opus-5-5', 'Opus 5.5', 'Deepest chess understanding, about twice the cost', 4.0, 20.0),
  haiku('claude-haiku-4-5-20251001', 'Haiku 4.5', 'Cheapest and fastest, lighter analysis', 1.0, 5.0);

  const CoachModel(this.id, this.label, this.blurb, this.inputPerMTok, this.outputPerMTok);

  final String id;
  final String label;
  final String blurb;

  /// Dollars per million tokens. Cache writes cost 1.25× input, cache reads 0.1× input.
  final double inputPerMTok;
  final double outputPerMTok;

  static CoachModel byName(String? name) =>
      CoachModel.values.firstWhere((m) => m.name == name, orElse: () => CoachModel.sonnet);
}

/// App-wide settings.
///
/// Plain preferences hold the username, model, engine depth and spending cap. Secrets (the
/// Anthropic API key and the optional Lichess study token) live in secure storage (Android
/// Keystore-backed) and only ever leave the phone as auth headers.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);

  static const _kUsername = 'lichess_username';
  static const _kApiKey = 'anthropic_api_key';
  static const _kLichessToken = 'lichess_study_token';
  static const _kModel = 'coach_model';
  static const _kDepth = 'engine_depth';
  static const _kCap = 'monthly_cap_dollars';
  static const _kStudy = 'last_study';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  String? _username;
  String? _apiKey;
  String? _lichessToken;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = AppSettings._(prefs);
    settings._username = prefs.getString(_kUsername);
    try {
      settings._apiKey = await settings._secure.read(key: _kApiKey);
      settings._lichessToken = await settings._secure.read(key: _kLichessToken);
    } catch (_) {
      settings._apiKey = null;
      settings._lichessToken = null;
    }
    return settings;
  }

  SharedPreferences get prefs => _prefs;

  String? get username => _username;
  String? get apiKey => _apiKey;
  String? get lichessToken => _lichessToken;
  bool get hasUsername => (_username ?? '').isNotEmpty;
  bool get hasApiKey => (_apiKey ?? '').isNotEmpty;
  bool get hasLichessToken => (_lichessToken ?? '').isNotEmpty;

  CoachModel get model => CoachModel.byName(_prefs.getString(_kModel));
  EngineDepth get depth => EngineDepth.byName(_prefs.getString(_kDepth));

  /// Monthly spending cap in dollars, or null for no cap.
  double? get monthlyCap => _prefs.getDouble(_kCap);

  /// Last study exported to, as "id|name".
  String? get lastStudy => _prefs.getString(_kStudy);

  Future<void> setUsername(String? value) async {
    final v = value?.trim();
    if (v == null || v.isEmpty) {
      await _prefs.remove(_kUsername);
      _username = null;
    } else {
      await _prefs.setString(_kUsername, v);
      _username = v;
    }
    notifyListeners();
  }

  Future<void> setApiKey(String? value) async {
    _apiKey = await _setSecret(_kApiKey, value);
    notifyListeners();
  }

  Future<void> setLichessToken(String? value) async {
    _lichessToken = await _setSecret(_kLichessToken, value);
    notifyListeners();
  }

  Future<String?> _setSecret(String key, String? value) async {
    final v = value?.trim();
    if (v == null || v.isEmpty) {
      await _secure.delete(key: key);
      return null;
    }
    await _secure.write(key: key, value: v);
    return v;
  }

  Future<void> setModel(CoachModel m) async {
    await _prefs.setString(_kModel, m.name);
    notifyListeners();
  }

  Future<void> setDepth(EngineDepth d) async {
    await _prefs.setString(_kDepth, d.name);
    notifyListeners();
  }

  Future<void> setMonthlyCap(double? dollars) async {
    if (dollars == null || dollars <= 0) {
      await _prefs.remove(_kCap);
    } else {
      await _prefs.setDouble(_kCap, dollars);
    }
    notifyListeners();
  }

  Future<void> setLastStudy(String id, String name) async {
    await _prefs.setString(_kStudy, '$id|$name');
    notifyListeners();
  }
}

/// A light check that a pasted string looks like an Anthropic API key.
bool looksLikeApiKey(String value) => value.trim().startsWith('sk-ant-');
