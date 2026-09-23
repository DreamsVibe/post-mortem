import 'package:flutter/material.dart';

import '../lichess_client.dart';
import '../settings.dart';
import '../theme.dart';

/// Change the linked Lichess account and the Anthropic API key.
///
/// Model, engine depth, usage and data controls arrive with the coach.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.settings, required this.lichess});

  final AppSettings settings;
  final LichessClient lichess;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _username = TextEditingController(text: widget.settings.username ?? '');
  final _apiKey = TextEditingController();
  String? _usernameError;
  String? _apiKeyError;
  bool _busy = false;

  @override
  void dispose() {
    _username.dispose();
    _apiKey.dispose();
    super.dispose();
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
      final found = await widget.lichess.lookUpUser(name);
      if (found == null) {
        setState(() => _usernameError = 'No Lichess player with that username.');
        return;
      }
      await widget.settings.setUsername(found);
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
    await widget.settings.setApiKey(key);
    _apiKey.clear();
    _toast('API key saved.');
  }

  Future<void> _clearApiKey() async {
    await widget.settings.setApiKey(null);
    _toast('API key removed.');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: widget.settings,
        builder: (context, _) {
          final key = widget.settings.apiKey;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text('Lichess username', style: text.titleSmall?.copyWith(color: kIvory)),
              const SizedBox(height: 8),
              TextField(
                controller: _username,
                enabled: !_busy,
                autocorrect: false,
                decoration: InputDecoration(errorText: _usernameError),
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
              const SizedBox(height: 28),
              Text('Anthropic API key', style: text.titleSmall?.copyWith(color: kIvory)),
              const SizedBox(height: 4),
              Text(
                key == null
                    ? 'No key saved yet. The coach needs one.'
                    : 'Saved: sk-ant-…${key.substring(key.length - 4)}',
                style: text.bodySmall?.copyWith(color: kIvoryMuted),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _apiKey,
                autocorrect: false,
                enableSuggestions: false,
                obscureText: true,
                decoration: InputDecoration(
                  hintText: key == null ? 'sk-ant-…' : 'Paste a new key to replace it',
                  errorText: _apiKeyError,
                ),
                onSubmitted: (_) => _saveApiKey(),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (key != null)
                    TextButton(onPressed: _clearApiKey, child: const Text('Remove key')),
                  const SizedBox(width: 8),
                  FilledButton.tonal(onPressed: _saveApiKey, child: const Text('Save key')),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
