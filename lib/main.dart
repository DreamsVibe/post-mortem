import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

const kInk = Color(0xFF1E1B18);
const kIvory = Color(0xFFF3EDE2);
const kAmber = Color(0xFFE0A43A);

void main() {
  runApp(const PostMortemApp());
}

class PostMortemApp extends StatelessWidget {
  const PostMortemApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Post Mortem',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kInk,
        colorScheme: ColorScheme.fromSeed(
          seedColor: kAmber,
          brightness: Brightness.dark,
          surface: kInk,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Post Mortem'),
        backgroundColor: kInk,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  return StaticChessboard(
                    size: constraints.maxWidth,
                    orientation: Side.white,
                    fen: kInitialBoardFEN,
                    shapes: {
                      Arrow(
                        color: kAmber.withValues(alpha: 0.85),
                        orig: Square.e2,
                        dest: Square.e4,
                      ),
                    },
                    settings: StaticChessboardSettings(
                      borderRadius: BorderRadius.circular(8),
                      colorScheme: ChessboardColorScheme.brown,
                    ),
                  );
                },
              ),
              const SizedBox(height: 24),
              Text(
                'The coach is on its way.',
                style: textTheme.titleLarge?.copyWith(color: kIvory),
              ),
              const SizedBox(height: 8),
              Text(
                'This first build checks that the app, the board and the '
                'cloud build all work. Game import and the Professor come next.',
                style: textTheme.bodyMedium?.copyWith(
                  color: kIvory.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
