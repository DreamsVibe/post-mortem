// Prints the board facts Post Mortem sends the Professor for a well-known game, so the output can
// be checked by eye. Run with: dart run tool/facts_demo.dart
import 'package:dartchess/dartchess.dart';
import 'package:post_mortem/src/engine/position_facts.dart';

// Paul Morphy vs Duke Karl / Count Isouard, Paris 1858 (the "Opera Game").
const _pgn = '''
[White "Morphy"]
[Black "Duke Karl / Count Isouard"]
[Result "1-0"]

1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 5. Qxf3 dxe5 6. Bc4 Nf6 7. Qb3 Qe7 8. Nc3 c6 9. Bg5 b5
10. Nxb5 cxb5 11. Bxb5+ Nbd7 12. O-O-O Rd8 13. Rxd7 Rxd7 14. Rd1 Qe6 15. Bxd7+ Nxd7 16. Qb8+ Nxb8
17. Rd8# 1-0
''';

void main() {
  final game = PgnGame.parsePgn(_pgn);
  Position pos = PgnGame.startingPosition(game.headers);
  final castled = <Side>{};
  var ply = 0;
  for (final node in game.moves.mainline()) {
    ply++;
    final move = pos.parseSan(node.san)!;
    final after = pos.play(move);
    print('ply $ply ${node.san}: ${PositionFacts.move(pos, move, after)}');
    if (node.san.startsWith('O-O')) castled.add(pos.turn);
    if (ply == 18 || ply == 19 || ply == 25) {
      print('--- position before ply ${ply + 1} ---');
      print(PositionFacts.diagram(after));
      print(PositionFacts.position(after, castled: castled, opening: true));
    }
    pos = after;
  }
  // A line check: after 9...b5, what does 10. Nxb5 achieve over the next moves?
  final start = PgnGame.parsePgn('1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 5. Qxf3 dxe5 6. Bc4 '
      'Nf6 7. Qb3 Qe7 8. Nc3 c6 9. Bg5 b5');
  Position p2 = Chess.initial;
  for (final n in start.moves.mainline()) {
    p2 = p2.play(p2.parseSan(n.san)!);
  }
  print('line from ply 18: ${PositionFacts.line(p2, ['c3b5', 'c6b5', 'c4b5', 'b8d7', 'e1c1'])}');
}
