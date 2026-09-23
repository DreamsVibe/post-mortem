import 'engine/game_analysis.dart';
import 'lichess_client.dart';
import 'settings.dart';
import 'storage.dart';

/// Long-lived app services, created once at startup.
class AppServices {
  AppServices({
    required this.settings,
    required this.lichess,
    required this.store,
    required this.analyzer,
  });

  final AppSettings settings;
  final LichessClient lichess;
  final LocalStore store;
  final GameAnalyzer analyzer;

  static Future<AppServices> create() async {
    final settings = await AppSettings.load();
    final store = await LocalStore.open();
    return AppServices(
      settings: settings,
      lichess: LichessClient(),
      store: store,
      analyzer: GameAnalyzer(store),
    );
  }
}

/// The app's services. Set once in main() before the first frame.
late final AppServices services;
