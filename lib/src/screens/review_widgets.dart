import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../coach/analysis_queue.dart';
import '../coach/chat.dart';
import '../coach/coach_models.dart';
import '../coach/usage.dart';
import '../engine/eval.dart';
import '../engine/game_analysis.dart';
import '../game_record.dart';
import '../theme.dart';

const kInaccuracy = Color(0xFFE6C45A);
const kMistake = Color(0xFFE8934A);
const kBlunder = Color(0xFFE0605A);

Color? qualityColor(MoveQuality? q) => switch (q) {
  MoveQuality.inaccuracy => kInaccuracy,
  MoveQuality.mistake => kMistake,
  MoveQuality.blunder => kBlunder,
  _ => null,
};

/// A move played on the board away from the game's own moves.
class VariationMove {
  const VariationMove(this.move, this.san, this.after);

  final Move move;
  final String san;
  final Position after;
}

/// How a Guess the move attempt went.
class GuessResult {
  const GuessResult({
    required this.ply,
    required this.guessSan,
    required this.playedSan,
    required this.bestSan,
    required this.verdict,
    required this.guessEval,
    required this.bestEval,
    required this.good,
  });

  /// The ply of the game move that was being guessed (1-based).
  final int ply;
  final String guessSan;
  final String playedSan;
  final String? bestSan;
  final String verdict;
  final Eval? guessEval;
  final Eval? bestEval;
  final bool good;
}

// ---- Top of the screen ----

/// Both players in the app bar: the top-of-board player on the left, the bottom one on the right.
class PlayersHeader extends StatelessWidget {
  const PlayersHeader({super.key, required this.left, required this.right});

  final GamePlayer left;
  final GamePlayer right;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _PlayerBlock(player: left, alignEnd: false)),
        const SizedBox(width: 12),
        Expanded(child: _PlayerBlock(player: right, alignEnd: true)),
      ],
    );
  }
}

class _PlayerBlock extends StatelessWidget {
  const _PlayerBlock({required this.player, required this.alignEnd});

  final GamePlayer player;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final diff = player.ratingDiff;
    return Column(
      crossAxisAlignment: alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          player.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: kIvory, fontSize: 16, fontWeight: FontWeight.w600),
        ),
        Text.rich(
          TextSpan(
            style: const TextStyle(color: kIvoryMuted, fontSize: 13),
            children: [
              if (player.isAi) const TextSpan(text: 'Computer'),
              if (player.rating != null) TextSpan(text: '${player.rating}'),
              if (diff != null)
                TextSpan(
                  text: '  ${diff >= 0 ? '+' : ''}$diff',
                  style: TextStyle(color: diff >= 0 ? kWin : kLoss),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Horizontal eval strip above the board: move verdict and evaluation, with the bar filled by
/// White's share of winning chances.
class EvalStrip extends StatelessWidget {
  const EvalStrip({
    super.key,
    required this.eval,
    required this.label,
    required this.labelColor,
    required this.orientation,
  });

  final Eval? eval;
  final String label;
  final Color? labelColor;
  final Side orientation;

  @override
  Widget build(BuildContext context) {
    final wc = eval?.whiteWinChance ?? 0;
    final whiteShare = ((wc + 1) / 2).clamp(0.04, 0.96);
    // The fill grows from the left for the side at the bottom of the board.
    final share = orientation == Side.white ? whiteShare : 1 - whiteShare;
    final fillColor = orientation == Side.white ? kIvory : const Color(0xFF3A3632);
    final restColor = orientation == Side.white ? const Color(0xFF3A3632) : kIvory;
    final onFill = orientation == Side.white ? kInk : kIvory;
    return SizedBox(
      height: 30,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: restColor)),
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerLeft,
                child: AnimatedFractionallySizedBox(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                  widthFactor: share,
                  heightFactor: 1,
                  child: ColoredBox(color: fillColor),
                ),
              ),
            ),
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    if (labelColor != null)
                      Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(color: labelColor, shape: BoxShape.circle),
                      ),
                    Text(
                      label,
                      style: TextStyle(
                        color: share > 0.3 ? onFill : (onFill == kInk ? kIvory : kInk),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      eval?.label ?? '',
                      style: TextStyle(
                        color: share > 0.85 ? onFill : (onFill == kInk ? kIvory : kInk),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Bottom controls ----

/// The one row of controls under the Professor's sheet.
class ReviewControls extends StatelessWidget {
  const ReviewControls({
    super.key,
    required this.guessOn,
    required this.onToggleGuess,
    required this.hasKeyMoments,
    required this.onPrevKey,
    required this.onNextKey,
    required this.onMoveList,
    required this.canBack,
    required this.canForward,
    required this.onBack,
    required this.onForward,
    required this.onStart,
    required this.onEnd,
  });

  final bool guessOn;
  final VoidCallback onToggleGuess;
  final bool hasKeyMoments;
  final VoidCallback onPrevKey;
  final VoidCallback onNextKey;
  final VoidCallback onMoveList;
  final bool canBack;
  final bool canForward;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onStart;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: const BoxDecoration(
        color: kInkRaised,
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        children: [
          _Pill(
            children: [
              IconButton(
                tooltip: guessOn ? 'Turn off Guess the move' : 'Turn on Guess the move',
                isSelected: guessOn,
                icon: const Icon(Icons.psychology_alt_outlined),
                selectedIcon: const Icon(Icons.psychology_alt),
                color: guessOn ? kAmber : kIvoryMuted,
                onPressed: onToggleGuess,
              ),
              IconButton(
                tooltip: 'All moves',
                icon: const Icon(Icons.format_list_numbered, color: kIvoryMuted),
                onPressed: onMoveList,
              ),
            ],
          ),
          const SizedBox(width: 8),
          if (hasKeyMoments)
            _Pill(
              children: [
                IconButton(
                  tooltip: 'Previous key moment',
                  icon: const Icon(Icons.keyboard_double_arrow_left, color: kAmber),
                  onPressed: onPrevKey,
                ),
                IconButton(
                  tooltip: 'Next key moment',
                  icon: const Icon(Icons.keyboard_double_arrow_right, color: kAmber),
                  onPressed: onNextKey,
                ),
              ],
            ),
          const Spacer(),
          _RoundButton(
            icon: Icons.chevron_left,
            tooltip: 'Previous move (hold for start)',
            onTap: canBack ? onBack : null,
            onLongPress: canBack ? onStart : null,
          ),
          const SizedBox(width: 10),
          _RoundButton(
            icon: Icons.chevron_right,
            tooltip: 'Next move (hold for end)',
            onTap: canForward ? onForward : null,
            onLongPress: canForward ? onEnd : null,
            primary: true,
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: kInk, borderRadius: BorderRadius.circular(28)),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.onLongPress,
    this.primary = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: primary && enabled ? kAmber : kInk,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          onLongPress: onLongPress,
          child: SizedBox(
            width: 56,
            height: 56,
            child: Icon(
              icon,
              size: 32,
              color: !enabled ? Colors.white24 : (primary ? kInk : kIvory),
            ),
          ),
        ),
      ),
    );
  }
}

// ---- The Professor's sheet ----

/// Header of the pull-up sheet: drag handle and the Notes / Chat tabs.
class SheetHeader extends StatelessWidget {
  const SheetHeader({
    super.key,
    required this.chatTab,
    required this.onTab,
    required this.chatCount,
    required this.onDrag,
    required this.onDragEnd,
  });

  final bool chatTab;
  final ValueChanged<bool> onTab;
  final int chatCount;
  final void Function(double dy) onDrag;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    Widget tab(String label, IconData icon, bool selected, VoidCallback onTap, {int badge = 0}) {
      return Expanded(
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: selected ? kAmber : Colors.transparent, width: 2),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: selected ? kAmber : kIvoryMuted),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? kIvory : kIvoryMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (badge > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: kAmber.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('$badge', style: const TextStyle(color: kAmber, fontSize: 11)),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (d) => onDrag(d.delta.dy),
      onVerticalDragEnd: (_) => onDragEnd(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 8, bottom: 4),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Row(
            children: [
              tab('Notes', Icons.school_outlined, !chatTab, () => onTab(false)),
              tab('Chat', Icons.forum_outlined, chatTab, () => onTab(true), badge: chatCount),
            ],
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}

/// "Move 12 of 31" with the move's verdict and the engine's best move.
class MoveHeadline extends StatelessWidget {
  const MoveHeadline({
    super.key,
    required this.game,
    required this.ply,
    required this.analysis,
    required this.isKeyMoment,
  });

  final GameRecord game;
  final int ply;
  final GameAnalysis? analysis;
  final bool isKeyMoment;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final quality = analysis?.qualityOf(ply);
    final bestBefore = ply > 0 ? analysis?.bestSanAt(ply - 1) : null;
    final showBest = quality != null &&
        quality != MoveQuality.best &&
        quality != MoveQuality.good &&
        bestBefore != null;
    final totalMoves = (game.plyCount + 1) ~/ 2;
    final moveNo = ply == 0 ? 0 : (ply + 1) ~/ 2;
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          ply == 0 ? 'Start' : game.moveLabel(ply),
          style: text.titleLarge?.copyWith(color: kIvory, fontWeight: FontWeight.w600),
        ),
        if (ply > 0) _Tag(text: 'Move $moveNo of $totalMoves', color: kIvoryMuted),
        if (isKeyMoment) const _Tag(text: '★ Key moment', color: kAmber),
        if (quality != null && ply > 0) QualityChip(quality: quality),
        if (showBest) _Tag(text: 'Best: $bestBefore', color: kWin),
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class QualityChip extends StatelessWidget {
  const QualityChip({super.key, required this.quality});

  final MoveQuality quality;

  @override
  Widget build(BuildContext context) {
    final color = qualityColor(quality) ?? (quality == MoveQuality.best ? kWin : kIvoryMuted);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        quality.label,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// The Professor's words for the current move: the story at the start, the note on each move,
/// and the recap at the end.
class CoachNotes extends StatelessWidget {
  const CoachNotes({super.key, required this.game, required this.ply, required this.review});

  final GameRecord game;
  final int ply;
  final CoachReview review;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final body = text.bodyLarge?.copyWith(color: kIvory, height: 1.5, fontSize: 16.5);
    final r = review;
    final children = <Widget>[];
    if (ply == 0) {
      children.addAll([
        const _SectionTitle(icon: Icons.menu_book_outlined, title: 'The story of the game'),
        const SizedBox(height: 6),
        Text(r.summary, style: body),
        if (r.openingName != null || r.openingIdeas != null) ...[
          const SizedBox(height: 16),
          _SectionTitle(icon: Icons.auto_stories_outlined, title: r.openingName ?? 'The opening'),
          if (r.leftTheoryAtPly != null && r.leftTheoryAtPly! <= game.plyCount)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Left master theory at ${game.moveLabel(r.leftTheoryAtPly!)}',
                style: text.bodySmall?.copyWith(color: kIvoryMuted),
              ),
            ),
          if (r.openingIdeas != null) ...[
            const SizedBox(height: 6),
            Text(r.openingIdeas!, style: body),
          ],
        ],
        const SizedBox(height: 12),
        Text(
          'Swipe left or tap › to step through the Professor\'s notes.',
          style: text.bodySmall?.copyWith(color: kIvoryMuted),
        ),
      ]);
    } else {
      final c = r.moves[ply];
      children.add(
        Text(
          c?.comment ?? 'No note for this move.',
          style: c == null ? body?.copyWith(color: kIvoryMuted) : body,
        ),
      );
      if (c != null && c.themes.isNotEmpty) {
        children.addAll([
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in c.themes)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(t, style: const TextStyle(color: kIvoryMuted, fontSize: 12.5)),
                ),
            ],
          ),
        ]);
      }
    }
    if (ply == game.plyCount && (r.recapText.isNotEmpty || r.lessons.isNotEmpty)) {
      children.addAll([
        const SizedBox(height: 20),
        const _SectionTitle(icon: Icons.flag_outlined, title: 'Recap'),
        const SizedBox(height: 6),
        Text(r.recapText, style: body),
        if (r.lessons.isNotEmpty) ...[
          const SizedBox(height: 14),
          const _SectionTitle(icon: Icons.lightbulb_outline, title: 'Lessons'),
          for (final l in r.lessons)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 3, right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: kAmber.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(l.area, style: const TextStyle(color: kAmber, fontSize: 11.5)),
                  ),
                  Expanded(child: Text(l.lesson, style: body)),
                ],
              ),
            ),
        ],
        const SizedBox(height: 10),
        Text(
          'Reviewed by ${r.model} · ${formatDollars(r.cost)}',
          style: text.bodySmall?.copyWith(color: kIvoryMuted),
        ),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: kAmber),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: kAmber,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// What the Notes tab shows before a review exists: the Analyze button, or the game's place in
/// the queue.
class CoachStatus extends StatelessWidget {
  const CoachStatus({
    super.key,
    required this.item,
    required this.analysisComplete,
    required this.blockedReason,
    required this.hasApiKey,
    required this.onAnalyze,
    required this.onRetry,
    required this.onOpenSettings,
    required this.onOpenQueue,
  });

  final QueueItem? item;
  final bool analysisComplete;
  final String? blockedReason;
  final bool hasApiKey;
  final VoidCallback onAnalyze;
  final VoidCallback onRetry;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenQueue;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final i = item;
    if (i != null && i.pending) {
      return InfoCard(
        accent: kAmber,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              i.state == QueueState.queued ? 'In the analysis queue' : 'The Professor is on it',
              style: text.titleSmall?.copyWith(color: kIvory, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(i.statusText, style: text.bodyMedium?.copyWith(color: kIvoryMuted)),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: i.state == QueueState.queued ? null : i.progress,
              minHeight: 3,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(height: 10),
            Text(
              'You can leave this game or look at others. The review keeps going in the queue '
              'and this game gets a coach icon in your list when it\'s ready.',
              style: text.bodySmall?.copyWith(color: kIvoryMuted, height: 1.4),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onOpenQueue, child: const Text('Open queue')),
            ),
          ],
        ),
      );
    }

    final failed = i != null && i.state == QueueState.failed;
    return InfoCard(
      accent: failed ? kLoss : kAmber,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Ask the Professor to review this game: the story of the game, a detailed note and '
            'arrows for every move, the key moments, and lessons at the end.',
            style: text.bodyMedium?.copyWith(color: kIvoryMuted, height: 1.4),
          ),
          if (failed) ...[
            const SizedBox(height: 8),
            Text(i.error ?? 'The review failed.', style: text.bodyMedium?.copyWith(color: kLoss)),
          ],
          if (blockedReason != null && hasApiKey) ...[
            const SizedBox(height: 8),
            Text(blockedReason!, style: text.bodySmall?.copyWith(color: kIvoryMuted)),
          ],
          const SizedBox(height: 12),
          if (!hasApiKey)
            FilledButton.icon(
              onPressed: onOpenSettings,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              icon: const Icon(Icons.key),
              label: const Text('Add API key in Settings'),
            )
          else
            FilledButton.icon(
              onPressed: blockedReason != null ? null : (failed ? onRetry : onAnalyze),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              icon: const Icon(Icons.school_outlined),
              label: Text(failed ? 'Try again' : 'Analyze with Coach'),
            ),
          if (!analysisComplete && hasApiKey && blockedReason == null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Stockfish is still analyzing; the queue finishes that first.',
                style: text.bodySmall?.copyWith(color: kIvoryMuted),
              ),
            ),
        ],
      ),
    );
  }
}

class InfoCard extends StatelessWidget {
  const InfoCard({super.key, required this.child, required this.accent});

  final Widget child;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kInk,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: child,
    );
  }
}

class GuessPrompt extends StatelessWidget {
  const GuessPrompt({
    super.key,
    required this.label,
    required this.side,
    required this.grading,
    required this.onSkip,
  });

  final String label;
  final Side side;
  final bool grading;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return InfoCard(
      accent: kAmber,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            grading ? 'Grading your move…' : 'Your move, ${side == Side.white ? 'White' : 'Black'}',
            style: text.titleMedium?.copyWith(color: kIvory, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            grading
                ? 'Stockfish is checking it against the best move.'
                : 'What would you play at move $label? Make your move on the board.',
            style: text.bodyMedium?.copyWith(color: kIvoryMuted),
          ),
          if (grading)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: LinearProgressIndicator(minHeight: 3),
            )
          else
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onSkip, child: const Text('Skip this one')),
            ),
        ],
      ),
    );
  }
}

class GuessCard extends StatelessWidget {
  const GuessCard({super.key, required this.result});

  final GuessResult result;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = result.good ? kWin : kMistake;
    final same = result.guessSan.replaceAll(RegExp(r'[+#]'), '') ==
        result.playedSan.replaceAll(RegExp(r'[+#]'), '');
    return InfoCard(
      accent: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(result.good ? Icons.check_circle : Icons.error_outline, color: color, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'You played ${result.guessSan}${result.guessEval != null ? ' (${result.guessEval!.label})' : ''}',
                  style: text.titleSmall?.copyWith(color: kIvory, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(result.verdict, style: text.bodyMedium?.copyWith(color: color)),
          const SizedBox(height: 4),
          Text(
            [
              if (result.bestSan != null)
                'Best: ${result.bestSan}${result.bestEval != null ? ' (${result.bestEval!.label})' : ''}',
              same ? 'Same as the game move.' : 'Game move: ${result.playedSan}',
            ].join('  ·  '),
            style: text.bodySmall?.copyWith(color: kIvoryMuted),
          ),
        ],
      ),
    );
  }
}

/// Side line the user is exploring on the board.
class ExplorationInfo extends StatelessWidget {
  const ExplorationInfo({
    super.key,
    required this.game,
    required this.branchPly,
    required this.variation,
    required this.liveEval,
    required this.onBackToGame,
  });

  final GameRecord game;
  final int branchPly;
  final List<VariationMove> variation;
  final PositionEval? liveEval;
  final VoidCallback onBackToGame;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final start = game.positions[branchPly];
    final line = variation.map((v) => v.san).join(' ');
    final best = liveEval == null
        ? null
        : uciLineToSan(variation.last.after, liveEval!.pv.take(4).toList()).join(' ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.alt_route, size: 18, color: kAmber),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Exploring from ${branchPly == 0 ? 'the start' : game.moveLabel(branchPly)}',
                style: text.titleSmall?.copyWith(color: kAmber),
              ),
            ),
            TextButton(onPressed: onBackToGame, child: const Text('Back to game')),
          ],
        ),
        Text(
          '${start.turn == Side.white ? '' : '… '}$line',
          style: text.titleMedium?.copyWith(color: kIvory),
        ),
        const SizedBox(height: 4),
        Text(
          liveEval == null
              ? 'Stockfish is thinking…'
              : 'Eval ${liveEval!.eval.label}${best != null && best.isNotEmpty ? '  ·  Best line: $best' : ''}',
          style: text.bodyMedium?.copyWith(color: kIvoryMuted),
        ),
        const SizedBox(height: 6),
        Text(
          'Ask the Professor about this line in the Chat tab.',
          style: text.bodySmall?.copyWith(color: kIvoryMuted),
        ),
      ],
    );
  }
}

class AnalysisProgress extends StatelessWidget {
  const AnalysisProgress({super.key, required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Stockfish is analyzing the game… $done / $total positions',
          style: const TextStyle(color: kIvoryMuted, fontSize: 13),
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(
          value: total == 0 ? null : done / total,
          minHeight: 4,
          borderRadius: BorderRadius.circular(2),
        ),
      ],
    );
  }
}

// ---- Chat ----

class ChatHistory extends StatelessWidget {
  const ChatHistory({
    super.key,
    required this.messages,
    required this.busy,
    required this.status,
    required this.error,
    required this.controller,
  });

  final List<ChatMessage> messages;
  final bool busy;
  final String? status;
  final String? error;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      children: [
        if (messages.isEmpty && !busy && error == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16, horizontal: 8),
            child: Text(
              'Ask anything about the position on the board: "What if I had played Nf3 here?", '
              '"Why is this a blunder?", "What do masters play here?". The Professor checks with '
              'Stockfish on your phone and Lichess before answering.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kIvoryMuted, height: 1.45),
            ),
          ),
        for (final m in messages) ChatBubble(message: m),
        if (busy)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Text(status ?? 'Thinking…', style: const TextStyle(color: kIvoryMuted)),
              ],
            ),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(error!, style: const TextStyle(color: kLoss)),
          ),
      ],
    );
  }
}

class ChatBubble extends StatelessWidget {
  const ChatBubble({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final user = message.fromUser;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.84),
        decoration: BoxDecoration(
          color: user ? kAmber.withValues(alpha: 0.18) : kInk,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              message.text,
              style: const TextStyle(color: kIvory, height: 1.45, fontSize: 15.5),
            ),
            if (!user && message.sources.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Sources: ${message.sources.join(' · ')}',
                style: const TextStyle(color: kIvoryMuted, fontSize: 11.5),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ChatInput extends StatelessWidget {
  const ChatInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.busy,
    required this.enabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool busy;
  final bool enabled;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              enabled: enabled && !busy,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(
                isDense: true,
                hintText: enabled
                    ? 'Ask the Professor about this position…'
                    : 'Add an API key in Settings to chat',
                fillColor: kInk,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Send',
            onPressed: enabled && !busy ? onSend : null,
            icon: busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send, color: kAmber),
          ),
        ],
      ),
    );
  }
}

// ---- Move list ----

/// Every move of the game in a grid, colored by quality; tap one to jump there.
class MoveListSheet extends StatelessWidget {
  const MoveListSheet({
    super.key,
    required this.game,
    required this.currentPly,
    required this.colors,
    required this.keyMoments,
    required this.onSelect,
  });

  final GameRecord game;
  final int currentPly;
  final Map<int, Color> colors;
  final Set<int> keyMoments;
  final void Function(int ply) onSelect;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: SingleChildScrollView(
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var ply = 1; ply <= game.plyCount; ply++)
                ChoiceChip(
                  selected: ply == currentPly,
                  onSelected: (_) => onSelect(ply),
                  showCheckmark: false,
                  avatar: keyMoments.contains(ply)
                      ? const Icon(Icons.star, size: 14, color: kAmber)
                      : null,
                  label: Text(
                    game.moveLabel(ply),
                    style: TextStyle(
                      color: ply == currentPly ? kInk : (colors[ply] ?? kIvory),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  selectedColor: kAmber,
                  backgroundColor: kInkRaised,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
