import 'coach/analysis_queue.dart';
import 'coach/chat.dart';
import 'coach/claude_client.dart';
import 'coach/narration.dart';
import 'coach/usage.dart';
import 'engine/engine_hub.dart';
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
    required this.usage,
    required this.coach,
    required this.chat,
    required this.hub,
    required this.queue,
  });

  final AppSettings settings;
  final LichessClient lichess;
  final LocalStore store;
  final GameAnalyzer analyzer;
  final UsageTracker usage;
  final CoachService coach;
  final ChatService chat;
  final EngineHub hub;
  final AnalysisQueue queue;

  static Future<AppServices> create() async {
    final settings = await AppSettings.load();
    final store = await LocalStore.open();
    final lichess = LichessClient();
    final usage = UsageTracker(settings.prefs, settings);
    final claude = ClaudeClient(settings);
    final analyzer = GameAnalyzer(store);
    final hub = EngineHub(analyzer, settings);
    final coach = CoachService(
      claude: claude,
      lichess: lichess,
      store: store,
      settings: settings,
      usage: usage,
    );
    return AppServices(
      settings: settings,
      lichess: lichess,
      store: store,
      analyzer: analyzer,
      usage: usage,
      coach: coach,
      chat: ChatService(claude: claude, lichess: lichess, settings: settings, usage: usage),
      hub: hub,
      queue: AnalysisQueue(hub: hub, coach: coach, store: store),
    );
  }
}

/// The app's services. Set once in main() before the first frame.
late final AppServices services;
