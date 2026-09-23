import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../settings.dart';
import 'usage.dart';

/// A failure calling Claude, with a message fit to show the user.
class ClaudeException implements Exception {
  const ClaudeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The parsed reply to one Messages API request.
class ClaudeResponse {
  const ClaudeResponse({required this.content, required this.stopReason, required this.usage});

  /// Raw content blocks (text, tool_use, …) as returned by the API.
  final List<Map<String, dynamic>> content;
  final String? stopReason;
  final TokenUsage usage;

  String get text => [
    for (final b in content)
      if (b['type'] == 'text') b['text'] as String,
  ].join('\n').trim();

  List<Map<String, dynamic>> get toolUses => [
    for (final b in content)
      if (b['type'] == 'tool_use') b,
  ];
}

/// Minimal client for the Claude Messages API, using the user's own API key.
class ClaudeClient {
  ClaudeClient(this._settings, {http.Client? client}) : _http = client ?? http.Client();

  static final _endpoint = Uri.parse('https://api.anthropic.com/v1/messages');

  final AppSettings _settings;
  final http.Client _http;

  Future<ClaudeResponse> send({
    required List<Map<String, dynamic>> system,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const [],
    Map<String, dynamic>? toolChoice,
    int maxTokens = 4096,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final key = _settings.apiKey;
    if (key == null || key.isEmpty) {
      throw const ClaudeException('Add your Anthropic API key in Settings to use the coach.');
    }
    final body = {
      'model': _settings.model.id,
      'max_tokens': maxTokens,
      'system': system,
      'messages': messages,
      if (tools.isNotEmpty) 'tools': tools,
      if (toolChoice != null) 'tool_choice': toolChoice,
    };

    http.Response res;
    try {
      res = await _http
          .post(
            _endpoint,
            headers: {
              'x-api-key': key,
              'anthropic-version': '2023-06-01',
              'content-type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const ClaudeException('Claude took too long to answer. Try again.');
    } catch (_) {
      throw const ClaudeException("Couldn't reach Claude. Check your connection and try again.");
    }

    final text = utf8.decode(res.bodyBytes);
    Map<String, dynamic>? json;
    try {
      json = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {}

    if (res.statusCode != 200) {
      final apiMessage = (json?['error'] as Map?)?['message'] as String?;
      throw ClaudeException(switch (res.statusCode) {
        401 => 'Your Anthropic API key was rejected. Check it in Settings.',
        403 => 'Your API key does not have access to this model.',
        429 => 'Claude is rate-limiting this key right now. Wait a minute and try again.',
        529 || 503 => 'Claude is overloaded right now. Try again in a moment.',
        400 when (apiMessage ?? '').contains('credit') =>
          'Your Anthropic account is out of credit. Add credit in the Claude Console.',
        _ => 'Claude returned an error (${res.statusCode})${apiMessage != null ? ': $apiMessage' : '.'}',
      });
    }
    if (json == null) throw const ClaudeException('Claude sent back a reply that could not be read.');

    return ClaudeResponse(
      content: [for (final b in (json['content'] as List? ?? const [])) (b as Map).cast()],
      stopReason: json['stop_reason'] as String?,
      usage: TokenUsage.fromJson((json['usage'] as Map?)?.cast()),
    );
  }
}
