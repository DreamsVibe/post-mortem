import '../game_record.dart';
import 'coach_models.dart';

/// Builds an annotated PGN of [game] with the Professor's comments, for export to a Lichess study.
String annotatedPgn(GameRecord game, CoachReview review) {
  String clean(String s) => s.replaceAll('{', '(').replaceAll('}', ')').replaceAll('\n', ' ').trim();
  String header(String k, String v) => '[$k "${v.replaceAll('"', "'")}"]';

  final start = game.positions.first;
  final b = StringBuffer()
    ..writeln(header('Event', 'Post Mortem review'))
    ..writeln(header('Site', game.id != null ? 'https://lichess.org/${game.id}' : '?'))
    ..writeln(header('White', game.white.name))
    ..writeln(header('Black', game.black.name))
    ..writeln(header('Result', game.result == GameResult.draw ? '1/2-1/2' : game.result.label));
  if (game.white.rating != null) b.writeln(header('WhiteElo', '${game.white.rating}'));
  if (game.black.rating != null) b.writeln(header('BlackElo', '${game.black.rating}'));
  if (review.openingName != null) b.writeln(header('Opening', review.openingName!));
  if (start.fen != _standardStartFen) {
    b
      ..writeln(header('SetUp', '1'))
      ..writeln(header('FEN', start.fen));
  }
  b.writeln();

  final body = StringBuffer();
  if (review.summary.isNotEmpty) body.write('{ ${clean(review.summary)} } ');
  for (var ply = 1; ply <= game.plyCount; ply++) {
    final label = game.moveLabel(ply);
    final isWhite = !label.contains('…');
    final number = label.split(RegExp(r'[.…]')).first;
    if (isWhite) {
      body.write('$number. ');
    } else if (ply == 1 || review.moves[ply - 1] != null) {
      body.write('$number... ');
    }
    body.write('${game.sans[ply - 1]} ');
    final c = review.moves[ply];
    if (c != null) {
      final arrows = [for (final a in c.arrows) '${_shapeColor(a.color)}${a.from.name}${a.to.name}'];
      final squares = [for (final h in c.highlights) 'Y${h.name}'];
      final tags = [
        if (arrows.isNotEmpty) '[%cal ${arrows.join(',')}]',
        if (squares.isNotEmpty) '[%csl ${squares.join(',')}]',
      ].join(' ');
      body.write('{ ${clean(c.comment)}${tags.isEmpty ? '' : ' $tags'} } ');
    }
  }
  if (review.recapText.isNotEmpty || review.lessons.isNotEmpty) {
    final lessons = review.lessons.map((l) => '${l.area}: ${l.lesson}').join(' / ');
    body.write('{ ${clean(review.recapText)}${lessons.isNotEmpty ? ' Lessons: ${clean(lessons)}' : ''} } ');
  }
  body.write(game.result == GameResult.draw ? '1/2-1/2' : game.result.label);
  b.writeln(body.toString());
  return b.toString();
}

String _shapeColor(String color) => switch (color) {
  'red' => 'R',
  'blue' => 'B',
  'yellow' => 'Y',
  _ => 'G',
};

const _standardStartFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
