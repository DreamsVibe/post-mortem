import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'game_record.dart';

/// Small JSON-file cache on the phone, one file per game per kind of data.
///
/// Kinds: `evals` (Stockfish analysis), `coach` (the Professor's review), `chat` (chat history).
class LocalStore {
  LocalStore._(this._root);

  final Directory _root;

  static Future<LocalStore> open() async {
    final base = await getApplicationDocumentsDirectory();
    final root = Directory('${base.path}/post_mortem');
    await root.create(recursive: true);
    return LocalStore._(root);
  }

  File _file(String kind, String key) => File('${_root.path}/$kind/$key.json');

  Future<Map<String, dynamic>?> read(String kind, String key) async {
    final f = _file(kind, key);
    try {
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String kind, String key, Map<String, dynamic> data) async {
    final f = _file(kind, key);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(data));
    await tmp.rename(f.path);
  }

  Future<void> delete(String kind, String key) async {
    final f = _file(kind, key);
    if (await f.exists()) await f.delete();
  }

  /// Deletes every cached file of the given kinds.
  Future<void> clear(List<String> kinds) async {
    for (final kind in kinds) {
      final dir = Directory('${_root.path}/$kind');
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  /// Keys of every cached file of [kind].
  Future<Set<String>> keys(String kind) async {
    final dir = Directory('${_root.path}/$kind');
    if (!await dir.exists()) return {};
    final out = <String>{};
    await for (final e in dir.list()) {
      final name = e.uri.pathSegments.last;
      if (name.endsWith('.json')) out.add(name.substring(0, name.length - 5));
    }
    return out;
  }

  /// Number of cached files of [kind].
  Future<int> count(String kind) async {
    final dir = Directory('${_root.path}/$kind');
    if (!await dir.exists()) return 0;
    return dir.list().where((e) => e.path.endsWith('.json')).length;
  }
}

/// A stable cache key for a game: its Lichess ID, or a hash of the moves for pasted PGNs.
String gameKey(GameRecord game) {
  if (game.id != null) return game.id!;
  final digest = sha1.convert(utf8.encode('${game.positions.first.fen}|${game.sans.join(' ')}'));
  return 'pgn_${digest.toString().substring(0, 16)}';
}
