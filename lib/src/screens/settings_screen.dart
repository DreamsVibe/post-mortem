import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../coach/usage.dart';
import '../engine/game_analysis.dart';
import '../lichess_client.dart';
import '../services.dart';
import '../settings.dart';
import '../theme.dart';

/// All settings: linked account, coach model and key, engine depth, spending, study export and
/// stored data.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppSettings get settings => services.settings;

  late final _username = TextEditingController(text: settings.username ?? '');
  final _apiKey = TextEditingController();
  final _token = TextEditingController();
  late final _cap = TextEditingController(
    text: settings.monthlyCap == null ? '' : settings.monthlyCap!.toStringAsFixed(2),
  );
  String? _usernameError;
  String? _apiKeyError;
  bool _busy = false;
  int? _reviews;
  int? _chats;
  int? _evals;

  @override
  void initState() {
    super.initState();
    _countData();
  }

  Future<void> _countData() async {
    final r = await services.store.count('coach');
    final c = await services.store.count('chat');
    final e = await services.store.count('evals');
    if (mounted) {
      setState(() {
        _reviews = r;
        _chats = c;
        _evals = e;
      });
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _apiKey.dispose();
    _token.dispose();
    _cap.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveUsername() async {
    final name = _username.text.trim();
    if (name.isEmpty) {
      setState(() => _usernameError = 'Enter a Lichess username.');
      return;
    }
    setState(() {
      _busy = true;
      _usernameError = null;
    });
    try {
      final found = await services.lichess.lookUpUser(name);
      if (found == null) {
        setState(() => _usernameError = 'No Lichess player with that username.');
        return;
      }
      await settings.setUsername(found);
      _username.text = found;
      _toast('Linked to $found.');
    } on LichessException catch (e) {
      setState(() => _usernameError = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveApiKey() async {
    final key = _apiKey.text.trim();
    if (!looksLikeApiKey(key)) {
      setState(() => _apiKeyError = 'Anthropic keys start with sk-ant-.');
      return;
    }
    setState(() => _apiKeyError = null);
    await settings.setApiKey(key);
    _apiKey.clear();
    _toast('API key saved.');
  }

  Future<void> _saveToken() async {
    final t = _token.text.trim();
    if (t.isEmpty) return;
    await settings.setLichessToken(t);
    _token.clear();
    _toast('Lichess study token saved.');
  }

  Future<void> _saveCap() async {
    final raw = _cap.text.trim().replaceAll('\$', '');
    if (raw.isEmpty) {
      await settings.setMonthlyCap(null);
      _toast('Monthly cap removed.');
      return;
    }
    final v = double.tryParse(raw);
    if (v == null || v <= 0) {
      _toast('Enter a dollar amount like 5 or 2.50, or leave it empty for no cap.');
      return;
    }
    await settings.setMonthlyCap(v);
    _toast('Monthly cap set to \$${v.toStringAsFixed(2)}.');
  }

  Future<void> _clearCoachData() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear coach data?'),
        content: const Text(
          'This deletes every saved Professor review and chat on this phone. Reviewing a game '
          'again will cost another Claude call. Stockfish analysis is kept.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true) return;
    await services.store.clear(['coach', 'chat']);
    await services.queue.forgetReviews();
    await _countData();
    _toast('Coach reviews and chats cleared.');
  }

  Future<void> _clearEngineData() async {
    await services.store.clear(['evals']);
    await _countData();
    _toast('Saved Stockfish analysis cleared.');
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: Listenable.merge([settings, services.usage]),
        builder: (context, _) {
          final key = settings.apiKey;
          final usage = services.usage;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
            children: [
              const _Section('Lichess account'),
              TextField(
                controller: _username,
                enabled: !_busy,
                autocorrect: false,
                decoration: InputDecoration(labelText: 'Username', errorText: _usernameError),
                onSubmitted: (_) => _saveUsername(),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  onPressed: _busy ? null : _saveUsername,
                  child: const Text('Save username'),
                ),
              ),

              const _Section('Coach'),
              Text(
                key == null ? 'No API key saved. The coach needs one.' : 'API key saved: sk-ant-…${key.substring(key.length - 4)}',
                style: text.bodySmall?.copyWith(color: kIvoryMuted),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _apiKey,
                autocorrect: false,
                enableSuggestions: false,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: key == null ? 'Anthropic API key' : 'Replace API key',
                  hintText: 'sk-ant-…',
                  errorText: _apiKeyError,
                ),
                onSubmitted: (_) => _saveApiKey(),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (key != null)
                    TextButton(
                      onPressed: () async {
                        await settings.setApiKey(null);
                        _toast('API key removed.');
                      },
                      child: const Text('Remove key'),
                    ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(onPressed: _saveApiKey, child: const Text('Save key')),
                ],
              ),
              const SizedBox(height: 16),
              Text('Coach model', style: text.titleSmall?.copyWith(color: kIvory)),
              const SizedBox(height: 8),
              SegmentedButton<CoachModel>(
                segments: [
                  for (final m in CoachModel.values)
                    ButtonSegment(value: m, label: Text(m.label)),
                ],
                selected: {settings.model},
                onSelectionChanged: (s) => settings.setModel(s.first),
              ),
              const SizedBox(height: 4),
              Text(
                '${settings.model.blurb}. \$${settings.model.inputPerMTok.toStringAsFixed(0)} per million input tokens, '
                '\$${settings.model.outputPerMTok.toStringAsFixed(0)} per million output tokens.',
                style: text.bodySmall?.copyWith(color: kIvoryMuted),
              ),

              const _Section('Stockfish'),
              SegmentedButton<EngineDepth>(
                segments: [
                  for (final d in EngineDepth.values)
                    ButtonSegment(value: d, label: Text(d.label)),
                ],
                selected: {settings.depth},
                onSelectionChanged: (s) => settings.setDepth(s.first),
              ),
              const SizedBox(height: 4),
              Text(
                'Depth ${settings.depth.depth}, up to ${(settings.depth.movetime.inMilliseconds / 1000).toStringAsFixed(1)} s per position. '
                'Applies to games analyzed from now on.',
                style: text.bodySmall?.copyWith(color: kIvoryMuted),
              ),

              const _Section('Usage'),
              Row(
                children: [
                  Expanded(
                    child: _Stat(label: 'This month', value: formatDollars(usage.thisMonth)),
                  ),
                  Expanded(
                    child: _Stat(label: 'Last month', value: formatDollars(usage.lastMonth)),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _cap,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Monthly spending cap (\$)',
                  hintText: 'Empty = no cap',
                ),
                onSubmitted: (_) => _saveCap(),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(onPressed: _saveCap, child: const Text('Save cap')),
              ),
              if (usage.capReached != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(usage.capReached!, style: text.bodySmall?.copyWith(color: kLoss)),
                ),
              const SizedBox(height: 12),
              if (usage.recent.isEmpty)
                Text('No coach calls yet.', style: text.bodySmall?.copyWith(color: kIvoryMuted))
              else ...[
                Text('Recent', style: text.titleSmall?.copyWith(color: kIvory)),
                for (final e in usage.recent.take(12))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 54,
                          child: Text(e.kind, style: const TextStyle(color: kAmber, fontSize: 13)),
                        ),
                        Expanded(
                          child: Text(
                            e.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: kIvory, fontSize: 13),
                          ),
                        ),
                        Text(
                          '${e.at.month}/${e.at.day}  ${formatDollars(e.cost)}',
                          style: const TextStyle(color: kIvoryMuted, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 4),
              Text(
                'Estimated from list prices; your Anthropic Console shows the exact bill.',
                style: text.bodySmall?.copyWith(color: kIvoryMuted),
              ),

              const _Section('Export to Lichess study'),
              Text(
                settings.hasLichessToken
                    ? 'Study token saved. Use "Export to Lichess study" in a review\'s menu.'
                    : 'To save reviews into your Lichess studies, create a personal token with study '
                          'access on Lichess and paste it here. It is stored encrypted on this phone.',
                style: text.bodySmall?.copyWith(color: kIvoryMuted),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Create a token on Lichess'),
                onPressed: () => launchUrl(
                  Uri.parse(
                    'https://lichess.org/account/oauth/token/create?scopes[]=study:read&scopes[]=study:write&description=Post%20Mortem',
                  ),
                  mode: LaunchMode.externalApplication,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _token,
                autocorrect: false,
                enableSuggestions: false,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: settings.hasLichessToken ? 'Replace token' : 'Lichess token',
                  hintText: 'lip_…',
                ),
                onSubmitted: (_) => _saveToken(),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (settings.hasLichessToken)
                    TextButton(
                      onPressed: () async {
                        await settings.setLichessToken(null);
                        _toast('Lichess token removed.');
                      },
                      child: const Text('Remove token'),
                    ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(onPressed: _saveToken, child: const Text('Save token')),
                ],
              ),

              const _Section('Data on this phone'),
              Text(
                '${_reviews ?? '…'} coach reviews · ${_chats ?? '…'} chats · ${_evals ?? '…'} analyzed games',
                style: text.bodySmall?.copyWith(color: kIvoryMuted),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(onPressed: _clearCoachData, child: const Text('Clear coach data')),
                  OutlinedButton(onPressed: _clearEngineData, child: const Text('Clear Stockfish analysis')),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 10),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: kAmber,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: kIvoryMuted, fontSize: 12)),
        Text(value, style: const TextStyle(color: kIvory, fontSize: 22, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
