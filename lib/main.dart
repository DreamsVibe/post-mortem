import 'package:flutter/material.dart';

import 'src/lichess_client.dart';
import 'src/screens/games_screen.dart';
import 'src/screens/setup_screen.dart';
import 'src/settings.dart';
import 'src/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  runApp(PostMortemApp(settings: settings, lichess: LichessClient()));
}

class PostMortemApp extends StatelessWidget {
  const PostMortemApp({super.key, required this.settings, required this.lichess});

  final AppSettings settings;
  final LichessClient lichess;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Post Mortem',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => settings.hasUsername
            ? GamesScreen(
                key: ValueKey(settings.username),
                settings: settings,
                lichess: lichess,
              )
            : SetupScreen(settings: settings, lichess: lichess),
      ),
    );
  }
}
