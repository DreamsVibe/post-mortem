import 'dart:async';

import 'package:flutter/material.dart';

import 'src/screens/games_screen.dart';
import 'src/screens/setup_screen.dart';
import 'src/services.dart';
import 'src/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  services = await AppServices.create();
  runApp(const PostMortemApp());
  // Resume any reviews that were waiting when the app was last closed.
  unawaited(services.queue.load());
}

class PostMortemApp extends StatelessWidget {
  const PostMortemApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = services.settings;
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
                lichess: services.lichess,
              )
            : SetupScreen(settings: settings, lichess: services.lichess),
      ),
    );
  }
}
