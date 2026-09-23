import 'dart:ui' show Color;

import 'package:dartchess/dartchess.dart';

/// An arrow the coach wants drawn on the board.
class CoachArrow {
  const CoachArrow(this.from, this.to, this.color);

  final Square from;
  final Square to;

  /// green / red / blue / yellow.
  final String color;

  Color get paint => switch (color) {
    'red' => const Color(0xCCE0605A),
    'blue' => const Color(0xCC5B9BD5),
    'yellow' => const Color(0xCCE6C45A),
    _ => const Color(0xCC6FB36B),
  };

  Map<String, dynamic> toJson() => {'from': from.name, 'to': to.name, 'color': color};
}

/// The Professor's comment on one move.
class MoveComment {
  const MoveComment({
    required this.ply,
    required this.san,
    required this.comment,
    this.label,
    this.phase,
    this.themes = const [],
    this.arrows = const [],
    this.highlights = const [],
  });

  final int ply;
  final String san;
  final String comment;
  final String? label;
  final String? phase;
  final List<String> themes;
  final List<CoachArrow> arrows;
  final List<Square> highlights;

  Map<String, dynamic> toJson() => {
    'ply': ply,
    'san': san,
    'comment': comment,
    if (label != null) 'label': label,
    if (phase != null) 'phase': phase,
    'themes': themes,
    'arrows': [for (final a in arrows) a.toJson()],
    'highlights': [for (final h in highlights) h.name],
  };
}

class Lesson {
  const Lesson(this.area, this.lesson);

  final String area;
  final String lesson;

  Map<String, dynamic> toJson() => {'area': area, 'lesson': lesson};
}

/// A full coach review of one game, as shown in the review screen and cached on the phone.
class CoachReview {
  const CoachReview({
    required this.summary,
    required this.openingName,
    required this.leftTheoryAtPly,
    required this.openingIdeas,
    required this.keyMoments,
    required this.moves,
    required this.recapText,
    required this.lessons,
    required this.model,
    required this.createdAt,
    required this.cost,
  });

  final String summary;
  final String? openingName;
  final int? leftTheoryAtPly;
  final String? openingIdeas;
  final List<int> keyMoments;

  /// Comment per ply (1-based: the move that led to positions[ply]).
  final Map<int, MoveComment> moves;
  final String recapText;
  final List<Lesson> lessons;
  final String model;
  final DateTime createdAt;
  final double cost;

  Map<String, dynamic> toJson() => {
    'summary': summary,
    'opening': {
      'name': openingName,
      'left_theory_at_ply': leftTheoryAtPly,
      'ideas': openingIdeas,
    },
    'key_moments': keyMoments,
    'moves': [for (final m in moves.values) m.toJson()],
    'recap': {
      'text': recapText,
      'lessons': [for (final l in lessons) l.toJson()],
    },
    'model': model,
    'createdAt': createdAt.toIso8601String(),
    'cost': cost,
  };

  static CoachReview fromJson(Map<String, dynamic> j) {
    final opening = (j['opening'] as Map?)?.cast<String, dynamic>();
    final recap = (j['recap'] as Map?)?.cast<String, dynamic>();
    final moves = <int, MoveComment>{};
    for (final raw in (j['moves'] as List? ?? const [])) {
      final m = parseMoveComment((raw as Map).cast());
      if (m != null) moves[m.ply] = m;
    }
    return CoachReview(
      summary: j['summary'] as String? ?? '',
      openingName: opening?['name'] as String?,
      leftTheoryAtPly: (opening?['left_theory_at_ply'] as num?)?.toInt(),
      openingIdeas: opening?['ideas'] as String?,
      keyMoments: [for (final k in (j['key_moments'] as List? ?? const [])) (k as num).toInt()],
      moves: moves,
      recapText: recap?['text'] as String? ?? '',
      lessons: [
        for (final l in (recap?['lessons'] as List? ?? const []))
          Lesson(
            (l as Map)['area'] as String? ?? 'general',
            l['lesson'] as String? ?? '',
          ),
      ],
      model: j['model'] as String? ?? '',
      createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
      cost: (j['cost'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// Parses one move comment, dropping malformed arrows and squares. Returns null if unusable.
MoveComment? parseMoveComment(Map<String, dynamic> j) {
  final ply = (j['ply'] as num?)?.toInt();
  final comment = (j['comment'] as String?)?.trim();
  if (ply == null || comment == null || comment.isEmpty) return null;
  final arrows = <CoachArrow>[];
  for (final a in (j['arrows'] as List? ?? const [])) {
    if (a is! Map) continue;
    final from = parseSquareName(a['from']);
    final to = parseSquareName(a['to']);
    if (from == null || to == null || from == to) continue;
    final color = (a['color'] as String? ?? 'green').toLowerCase();
    arrows.add(CoachArrow(from, to, const ['green', 'red', 'blue', 'yellow'].contains(color) ? color : 'green'));
  }
  final highlights = <Square>[
    for (final h in (j['highlights'] as List? ?? const []))
      if (parseSquareName(h) != null) parseSquareName(h)!,
  ];
  return MoveComment(
    ply: ply,
    san: j['san'] as String? ?? '',
    comment: comment,
    label: j['label'] as String?,
    phase: j['phase'] as String?,
    themes: [
      for (final t in (j['themes'] as List? ?? const []))
        if (t is String) t,
    ],
    arrows: arrows.take(3).toList(),
    highlights: highlights.take(4).toList(),
  );
}

Square? parseSquareName(Object? v) {
  if (v is! String) return null;
  final s = v.trim().toLowerCase();
  if (!RegExp(r'^[a-h][1-8]$').hasMatch(s)) return null;
  return Square.parse(s);
}
