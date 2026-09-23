import 'package:flutter/material.dart';

import '../lichess_client.dart';
import '../settings.dart';
import '../theme.dart';

/// First-run screen: link a Lichess username and, optionally, an API key.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.settings, required this.lichess});

  final AppSettings settings;
  final LichessClient lichess;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _username = TextEditingController();
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

  Future<void> _continue() async {
    final name = _username.text.trim();
    final key = _apiKey.text.trim();
    setState(() {
      _usernameError = name.isEmpty ? 'Enter your Lichess username.' : null;
      _apiKeyError = key.isNotEmpty && !looksLikeApiKey(key)
          ? 'Anthropic keys start with sk-ant-. Leave it empty to add one later.'
          : null;
    });
    if (_usernameError != null || _apiKeyError != null) return;

    setState(() => _busy = true);
    try {
      final found = await widget.lichess.lookUpUser(name);
      if (found == null) {
        setState(() => _usernameError = 'No Lichess player with that username.');
        return;
      }
      if (key.isNotEmpty) await widget.settings.setApiKey(key);
      await widget.settings.setUsername(found);
    } on LichessException catch (e) {
      setState(() => _usernameError = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
          children: [
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset('assets/icon.png', width: 96, height: 96),
              ),
            ),
            const SizedBox(height: 24),
            Text('Post Mortem',
                textAlign: TextAlign.center,
                style: text.headlineMedium?.copyWith(color: kIvory, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              'Review your Lichess games with the Professor.',
              textAlign: TextAlign.center,
              style: text.bodyLarge?.copyWith(color: kIvoryMuted),
            ),
            const SizedBox(height: 40),
            Text('Lichess username', style: text.titleSmall?.copyWith(color: kIvory)),
            const SizedBox(height: 8),
            TextField(
              controller: _username,
              enabled: !_busy,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                hintText: 'e.g. DreamsVibe',
                errorText: _usernameError,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Your games are public on Lichess, so only the name is needed. No password, no login.',
              style: text.bodySmall?.copyWith(color: kIvoryMuted),
            ),
            const SizedBox(height: 28),
            Text('Anthropic API key (optional for now)', style: text.titleSmall?.copyWith(color: kIvory)),
            const SizedBox(height: 8),
            TextField(
              controller: _apiKey,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              obscureText: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _continue(),
              decoration: InputDecoration(
                hintText: 'sk-ant-…',
                errorText: _apiKeyError,
                errorMaxLines: 3,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Powers the coach. Stored encrypted on this phone and only sent to Anthropic. You can add it later in Settings.',
              style: text.bodySmall?.copyWith(color: kIvoryMuted),
            ),
            const SizedBox(height: 36),
            FilledButton(
              onPressed: _busy ? null : _continue,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: _busy
                  ? const SizedBox(
                      width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }
}
