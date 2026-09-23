import 'dart:convert';

import 'package:http/http.dart' as http;

import 'game_record.dart';

/// A failure talking to Lichess, with a message fit to show the user.
class LichessException implements Exception {
  const LichessException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Read-only client for Lichess's public API. Nothing here needs a login.
class LichessClient {
  LichessClient({http.Client? client}) : _http = client ?? http.Client();

  static const _host = 'lichess.org';
  static const _userAgent = 'PostMortem/0.1 (+https://github.com/DreamsVibe/post-mortem)';

  final http.Client _http;

  /// Returns the correctly-cased username, or null if no such account exists.
  Future<String?> lookUpUser(String username) async {
    final res = await _get(Uri.https(_host, '/api/user/${username.trim()}'),
        accept: 'application/json');
    if (res.statusCode == 404) return null;
    _check(res);
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    if (json['disabled'] == true) return null;
    return json['username'] as String? ?? username.trim();
  }

  /// The most recent finished standard games of [username], newest first.
  Future<List<GameRecord>> userGames(String username, {int max = 30}) async {
    final uri = Uri.https(_host, '/api/games/user/${username.trim()}', {
      'max': '$max',
      'moves': 'true',
      'opening': 'true',
      'finished': 'true',
      'pgnInJson': 'false',
      'clocks': 'false',
      'evals': 'false',
    });
    final res = await _get(uri, accept: 'application/x-ndjson');
    if (res.statusCode == 404) {
      throw const LichessException('No Lichess player with that username.');
    }
    _check(res);
    final games = <GameRecord>[];
    for (final line in const LineSplitter().convert(utf8.decode(res.bodyBytes))) {
      if (line.trim().isEmpty) continue;
      final record = GameRecord.fromLichessJson(jsonDecode(line) as Map<String, dynamic>);
      if (record != null && record.plyCount > 0) games.add(record);
    }
    return games;
  }

  /// One game by its 8-character Lichess ID.
  Future<GameRecord> game(String id) async {
    final uri = Uri.https(_host, '/game/export/$id', {
      'moves': 'true',
      'opening': 'true',
      'pgnInJson': 'false',
      'clocks': 'false',
      'evals': 'false',
    });
    final res = await _get(uri, accept: 'application/json');
    if (res.statusCode == 404) {
      throw const LichessException('That game could not be found on Lichess.');
    }
    _check(res);
    final record = GameRecord.fromLichessJson(jsonDecode(res.body) as Map<String, dynamic>);
    if (record == null) {
      throw const LichessException('Only standard chess games are supported for now.');
    }
    return record;
  }

  Future<http.Response> _get(Uri uri, {required String accept}) async {
    try {
      return await _http
          .get(uri, headers: {'Accept': accept, 'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      throw const LichessException("Couldn't reach Lichess. Check your connection and try again.");
    }
  }

  void _check(http.Response res) {
    if (res.statusCode == 429) {
      throw const LichessException('Lichess asked us to slow down. Try again in a minute.');
    }
    if (res.statusCode >= 400) {
      throw LichessException('Lichess returned an error (${res.statusCode}).');
    }
  }
}

/// Pulls an 8-character Lichess game ID out of a link or a bare ID, if present.
String? parseLichessGameId(String input) {
  final text = input.trim();
  final link = RegExp(r'lichess\.org/([A-Za-z0-9]{8})(?:[A-Za-z0-9]{4})?(?:[/?#]|$)').firstMatch(text);
  if (link != null) return link.group(1);
  if (RegExp(r'^[A-Za-z0-9]{8}([A-Za-z0-9]{4})?$').hasMatch(text)) return text.substring(0, 8);
  return null;
}
