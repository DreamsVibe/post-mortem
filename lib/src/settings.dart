import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide settings: the linked Lichess username and the Anthropic API key.
///
/// The username is a plain preference. The API key lives in secure storage
/// (Android Keystore-backed) and never leaves the phone except as the auth
/// header of Claude API calls.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);

  static const _kUsername = 'lichess_username';
  static const _kApiKey = 'anthropic_api_key';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  String? _username;
  String? _apiKey;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = AppSettings._(prefs);
    settings._username = prefs.getString(_kUsername);
    try {
      settings._apiKey = await settings._secure.read(key: _kApiKey);
    } catch (_) {
      settings._apiKey = null;
    }
    return settings;
  }

  String? get username => _username;
  String? get apiKey => _apiKey;
  bool get hasUsername => (_username ?? '').isNotEmpty;
  bool get hasApiKey => (_apiKey ?? '').isNotEmpty;

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
    final v = value?.trim();
    if (v == null || v.isEmpty) {
      await _secure.delete(key: _kApiKey);
      _apiKey = null;
    } else {
      await _secure.write(key: _kApiKey, value: v);
      _apiKey = v;
    }
    notifyListeners();
  }
}

/// A light check that a pasted string looks like an Anthropic API key.
bool looksLikeApiKey(String value) => value.trim().startsWith('sk-ant-');
