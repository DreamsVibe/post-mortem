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

  /// Finished standard games of [username], newest first.
  ///
  /// Pass [until] (exclusive) to fetch the page of games played before it.
  /// Lichess streams exports at roughly 20 games per second, so pages stay modest.
  /// [fetched] is the number of games Lichess returned, including variants that were
  /// filtered out, so callers can tell whether older games remain.
  Future<({List<GameRecord> games, int fetched})> userGames(
    String username, {
    int max = 50,
    DateTime? until,
  }) async {
    final uri = Uri.https(_host, '/api/games/user/${username.trim()}', {
      'max': '$max',
      'moves': 'true',
      'opening': 'true',
      'finished': 'true',
      'pgnInJson': 'false',
      'clocks': 'false',
      'evals': 'false',
      if (until != null) 'until': '${until.millisecondsSinceEpoch - 1}',
    });
    final res = await _get(uri, accept: 'application/x-ndjson', timeout: 60);
    if (res.statusCode == 404) {
      throw const LichessException('No Lichess player with that username.');
    }
    _check(res);
    final games = <GameRecord>[];
    var fetched = 0;
    for (final line in const LineSplitter().convert(utf8.decode(res.bodyBytes))) {
      if (line.trim().isEmpty) continue;
      fetched++;
      final record = GameRecord.fromLichessJson(jsonDecode(line) as Map<String, dynamic>);
      if (record != null && record.plyCount > 0) games.add(record);
    }
    return (games: games, fetched: fetched);
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

  // ---- Lookups used by the coach ----

  /// Opening explorer stats for a position. [source] is "masters", "lichess" or "player".
  ///
  /// Returns null when the explorer can't be used (for example if Lichess requires a login for
  /// it), so callers can carry on without it.
  Future<Map<String, dynamic>?> openingExplorer(
    String fen, {
    String source = 'masters',
    List<String>? speeds,
    List<int>? ratings,
    String? player,
    String? color,
    int moves = 6,
    String? token,
  }) async {
    final params = <String, String>{
      'fen': fen,
      'moves': '$moves',
      'topGames': '0',
      'recentGames': '0',
      if (source == 'lichess') 'variant': 'standard',
      if (speeds != null && speeds.isNotEmpty) 'speeds': speeds.join(','),
      if (ratings != null && ratings.isNotEmpty) 'ratings': ratings.join(','),
      if (source == 'player' && player != null) 'player': player,
      if (source == 'player') 'color': color ?? 'white',
    };
    final uri = Uri.https('explorer.lichess.org', '/$source', params);
    final http.Response res;
    try {
      res = await _http
          .get(uri, headers: {
            'Accept': 'application/json',
            'User-Agent': _userAgent,
            if (token != null) 'Authorization': 'Bearer $token',
          })
          .timeout(const Duration(seconds: 25));
    } catch (_) {
      return null;
    }
    if (res.statusCode != 200) return null;
    // The player explorer streams progressively better answers as NDJSON; keep the last one.
    final lines = const LineSplitter()
        .convert(utf8.decode(res.bodyBytes))
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;
    try {
      return jsonDecode(lines.last) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Endgame tablebase verdict for positions with 7 or fewer pieces, or null if unavailable.
  Future<Map<String, dynamic>?> tablebase(String fen) async {
    final uri = Uri.https('tablebase.lichess.org', '/standard', {'fen': fen});
    try {
      final res = await _get(uri, accept: 'application/json');
      if (res.statusCode != 200) return null;
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Public profile of a player (ratings per time control, game counts).
  Future<Map<String, dynamic>?> user(String username) async {
    final res = await _get(Uri.https(_host, '/api/user/${username.trim()}'), accept: 'application/json');
    if (res.statusCode == 404) return null;
    _check(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Rating history per time control.
  Future<List<dynamic>> ratingHistory(String username) async {
    final res = await _get(
      Uri.https(_host, '/api/user/${username.trim()}/rating-history'),
      accept: 'application/json',
    );
    _check(res);
    return jsonDecode(res.body) as List<dynamic>;
  }

  /// A player's recent games, optionally filtered by time control or opponent.
  Future<List<GameRecord>> filteredGames(
    String username, {
    int max = 10,
    String? perfType,
    String? vs,
  }) async {
    final uri = Uri.https(_host, '/api/games/user/${username.trim()}', {
      'max': '${max.clamp(1, 20)}',
      'moves': 'true',
      'opening': 'true',
      'finished': 'true',
      'clocks': 'false',
      'evals': 'false',
      if (perfType != null) 'perfType': perfType,
      if (vs != null) 'vs': vs,
    });
    final res = await _get(uri, accept: 'application/x-ndjson', timeout: 30);
    _check(res);
    final games = <GameRecord>[];
    for (final line in const LineSplitter().convert(utf8.decode(res.bodyBytes))) {
      if (line.trim().isEmpty) continue;
      final g = GameRecord.fromLichessJson(jsonDecode(line) as Map<String, dynamic>);
      if (g != null) games.add(g);
    }
    return games;
  }

  // ---- Study export (needs a personal token with study:write) ----

  /// The studies of [username] visible with [token], as (id, name) pairs.
  Future<List<(String, String)>> studies(String username, String token) async {
    final http.Response res;
    try {
      res = await _http
          .get(
            Uri.https(_host, '/api/study/by/${username.trim()}'),
            headers: {
              'Accept': 'application/x-ndjson',
              'Authorization': 'Bearer $token',
              'User-Agent': _userAgent,
            },
          )
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      throw const LichessException("Couldn't reach Lichess. Check your connection and try again.");
    }
    if (res.statusCode == 401) {
      throw const LichessException('Lichess rejected the study token. Create a new one in Settings.');
    }
    _check(res);
    return [
      for (final line in const LineSplitter().convert(utf8.decode(res.bodyBytes)))
        if (line.trim().isNotEmpty)
          () {
            final j = jsonDecode(line) as Map<String, dynamic>;
            return (j['id'] as String, j['name'] as String? ?? j['id'] as String);
          }(),
    ];
  }

  /// Adds [pgn] as a new chapter of study [studyId]. Returns the chapter URL.
  Future<String> importToStudy(String studyId, String pgn, String name, String token) async {
    final http.Response res;
    try {
      res = await _http
          .post(
            Uri.https(_host, '/api/study/$studyId/import-pgn'),
            headers: {'Authorization': 'Bearer $token', 'User-Agent': _userAgent},
            body: {'pgn': pgn, 'name': name},
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const LichessException("Couldn't reach Lichess. Check your connection and try again.");
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw const LichessException(
        "Lichess refused the export. Check that the token has study write access and that you "
        "can edit this study.",
      );
    }
    _check(res);
    try {
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final chapters = j['chapters'] as List?;
      final chapterId = chapters != null && chapters.isNotEmpty
          ? (chapters.last as Map)['id'] as String?
          : null;
      return chapterId == null
          ? 'https://lichess.org/study/$studyId'
          : 'https://lichess.org/study/$studyId/$chapterId';
    } catch (_) {
      return 'https://lichess.org/study/$studyId';
    }
  }

  Future<http.Response> _get(Uri uri, {required String accept, int timeout = 20}) async {
    try {
      return await _http
          .get(uri, headers: {'Accept': accept, 'User-Agent': _userAgent})
          .timeout(Duration(seconds: timeout));
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
