import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RonghorAIApp());
}

const brandPurple = Color(0xFF8B5CF6);
const brandBlue = Color(0xFF38BDF8);

/// Optional default server address baked in at build time (GitHub variable BACKEND_URL).
const defaultBackendUrl = String.fromEnvironment('BACKEND_URL');

class _ApiException implements Exception {
  final int status;
  final String detail;
  _ApiException(this.status, this.detail);
}

Map<String, String> _headers(String key) => {
      'Content-Type': 'application/json',
      if (key.isNotEmpty) 'Authorization': 'Bearer $key',
    };

String _normalizeUrl(String raw) =>
    raw.trim().replaceAll(RegExp(r'/chat/*$'), '').replaceAll(RegExp(r'/+$'), '');

String _extractDetail(String body) {
  try {
    final data = jsonDecode(body);
    if (data is Map && data['detail'] != null) {
      final detail = data['detail'];
      return detail is String ? detail : jsonEncode(detail);
    }
  } catch (_) {
    // Not JSON: fall through to the raw text below.
  }
  return body.length > 300 ? body.substring(0, 300) : body;
}

String _friendlyError(Object e) {
  if (e is _ApiException) {
    if (e.status == 401) {
      return 'Wrong or missing access key. Open Settings (sliders icon) and check it.';
    }
    if (e.status == 404) {
      return 'The server answered, but it does not look like the Ronghor AI backend (404). Check the backend URL in Settings.';
    }
    return e.detail.isEmpty ? 'Server error ${e.status}.' : e.detail;
  }
  if (e is TimeoutException) {
    return 'The server took too long to answer. If it was asleep, wait a few seconds and try again.';
  }
  if (e is FormatException) {
    return 'The server sent a reply the app could not read. Check the backend URL in Settings.';
  }
  return 'Could not reach the server. Check the backend URL in Settings and your internet connection. ($e)';
}

class RonghorAIApp extends StatelessWidget {
  const RonghorAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ronghor AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B1020),
        colorScheme: ColorScheme.fromSeed(
          seedColor: brandPurple,
          brightness: Brightness.dark,
          surface: const Color(0xFF121A2B),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B1020),
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: const ChatScreen(),
    );
  }
}

class ChatMessage {
  final String role;
  final String content;
  final bool isError; // shown on screen only; never saved or sent to the AI
  ChatMessage(this.role, this.content, {this.isError = false});

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
  factory ChatMessage.fromJson(Map<String, dynamic> json) =>
      ChatMessage(json['role'] as String, json['content'] as String);
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _tts = FlutterTts();
  final _speech = stt.SpeechToText();
  final List<ChatMessage> _messages = [];
  String _baseUrl = defaultBackendUrl;
  String _accessKey = '';
  bool _busy = false;
  bool _webSearch = false;
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    _loadSettingsAndHistory();
    _tts.setLanguage('en-IN');
  }

  Future<void> _loadSettingsAndHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('backend_url');
    final key = prefs.getString('access_key');
    final saved = prefs.getString('chat_history');
    if (!mounted) return;
    setState(() {
      if (url != null && url.trim().isNotEmpty) _baseUrl = url.trim();
      if (key != null) _accessKey = key;
      if (saved != null) {
        try {
          final decoded = jsonDecode(saved) as List<dynamic>;
          _messages.addAll(decoded.map((e) =>
              ChatMessage.fromJson(Map<String, dynamic>.from(e as Map))));
        } catch (_) {
          // Ignore an invalid old history and start with an empty conversation.
        }
      }
      if (_messages.isEmpty) {
        _messages.add(ChatMessage(
          'assistant',
          'Hello! I’m Ronghor AI. Ask me anything. First time? Tap the sliders icon (top right) to enter your server address and access key.',
        ));
      }
    });
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'chat_history',
      jsonEncode(_messages.where((m) => !m.isError).map((m) => m.toJson()).toList()),
    );
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _busy) return;
    if (_baseUrl.isEmpty) {
      setState(() => _messages.add(ChatMessage(
            'assistant',
            'No server address yet. Tap the sliders icon (top right) and enter your Ronghor AI server URL and access key.',
            isError: true,
          )));
      _jumpToBottom();
      return;
    }
    _controller.clear();
    final userMessage = ChatMessage('user', text);
    final history = _messages
        .where((m) => !m.isError && (m.role == 'user' || m.role == 'assistant'))
        .toList();
    final recent =
        history.length > 12 ? history.sublist(history.length - 12) : history;
    setState(() {
      _messages.add(userMessage);
      _busy = true;
    });
    await _saveHistory();
    _jumpToBottom();

    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/chat'),
            headers: _headers(_accessKey),
            body: jsonEncode({
              'message': text,
              'web_search': _webSearch,
              'history': recent.map((m) => m.toJson()).toList(),
            }),
          )
          .timeout(const Duration(seconds: 120));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _ApiException(response.statusCode, _extractDetail(response.body));
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final answer =
          (data['answer'] ?? 'The AI returned an empty response.').toString();
      if (!mounted) return;
      setState(() => _messages.add(ChatMessage('assistant', answer)));
      await _saveHistory();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.remove(userMessage);
        _messages.add(ChatMessage('assistant', _friendlyError(e), isError: true));
        if (_controller.text.isEmpty) _controller.text = text;
      });
      await _saveHistory();
    } finally {
      if (mounted) setState(() => _busy = false);
      _jumpToBottom();
    }
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _toggleVoiceInput() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    final available = await _speech.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          if (mounted) setState(() => _listening = false);
        }
      },
      onError: (_) {
        if (mounted) setState(() => _listening = false);
      },
    );
    if (!available) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Speech recognition is unavailable on this device.')),
        );
      }
      return;
    }
    setState(() => _listening = true);
    await _speech.listen(
      onResult: (result) {
        _controller.text = result.recognizedWords;
        _controller.selection = TextSelection.fromPosition(
          TextPosition(offset: _controller.text.length),
        );
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _speak(String text) async {
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<String> _testConnection(String url, String key) async {
    if (url.isEmpty) return 'Enter the backend URL first.';
    try {
      final r = await http
          .get(Uri.parse('$url/ping'), headers: _headers(key))
          .timeout(const Duration(seconds: 70));
      if (r.statusCode < 200 || r.statusCode >= 300) {
        throw _ApiException(r.statusCode, _extractDetail(r.body));
      }
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      if (data['ai_configured'] != true) {
        return 'Connected, but the server has no AI key yet: ${data['problem'] ?? 'add ANTHROPIC_API_KEY on the server.'}';
      }
      return 'Connected. Using ${data['provider']} (${data['model']}).';
    } catch (e) {
      return _friendlyError(e);
    }
  }

  Future<void> _openSettings() async {
    final urlController = TextEditingController(text: _baseUrl);
    final keyController = TextEditingController(text: _accessKey);
    String? testResult;
    var testing = false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Ronghor AI settings'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Backend URL', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                TextField(
                  controller: urlController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    hintText: 'https://ronghor-ai-api.onrender.com',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Access key', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                TextField(
                  controller: keyController,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    hintText: 'The APP_ACCESS_KEY from your server',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: testing
                      ? null
                      : () async {
                          setDialogState(() {
                            testing = true;
                            testResult = 'Testing… a sleeping server can take up to a minute.';
                          });
                          final message = await _testConnection(
                            _normalizeUrl(urlController.text),
                            keyController.text.trim(),
                          );
                          if (!ctx.mounted) return;
                          setDialogState(() {
                            testing = false;
                            testResult = message;
                          });
                        },
                  icon: const Icon(Icons.wifi_tethering, size: 18),
                  label: const Text('Test connection'),
                ),
                if (testResult != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      testResult!,
                      style: const TextStyle(fontSize: 12.5, color: Colors.white70),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;

    final url = _normalizeUrl(urlController.text);
    final key = keyController.text.trim();
    if (!mounted) return;
    if (url.isNotEmpty && !RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The backend URL must start with https://')),
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('backend_url', url);
    await prefs.setString('access_key', key);
    if (!mounted) return;
    setState(() {
      _baseUrl = url;
      _accessKey = key;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings saved')),
    );
  }

  Future<void> _clearChat() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear conversation?'),
        content: const Text('This removes the locally saved chat history on this phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _messages
        ..clear()
        ..add(ChatMessage('assistant', 'New conversation started. What would you like to explore?'));
    });
    await _saveHistory();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _tts.stop();
    _speech.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leadingWidth: 54,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12, top: 8, bottom: 8),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              gradient: const LinearGradient(colors: [brandPurple, brandBlue]),
            ),
            child: const Icon(Icons.auto_awesome_rounded, color: Colors.white),
          ),
        ),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Ronghor AI', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: .2)),
            Text('Your AI companion', style: TextStyle(fontSize: 11, color: Colors.white60)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Clear chat',
            onPressed: _clearChat,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: _openSettings,
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.fromLTRB(14, 4, 14, 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF121A2B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.public, size: 19, color: brandBlue),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('Web search', style: TextStyle(fontWeight: FontWeight.w600))),
                  Switch(
                    value: _webSearch,
                    onChanged: (value) => setState(() => _webSearch = value),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
                itemCount: _messages.length + (_busy ? 1 : 0),
                itemBuilder: (context, index) {
                  if (_busy && index == _messages.length) {
                    return const Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 10),
                          Text('Ronghor AI is thinking…', style: TextStyle(color: Colors.white70)),
                        ]),
                      ),
                    );
                  }
                  final message = _messages[index];
                  final isUser = message.role == 'user';
                  final isError = message.isError;
                  return Align(
                    alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .86),
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      padding: const EdgeInsets.fromLTRB(14, 11, 10, 8),
                      decoration: BoxDecoration(
                        gradient: isUser
                            ? const LinearGradient(colors: [Color(0xFF6D4AFF), Color(0xFF4C6FFF)])
                            : null,
                        color: isUser ? null : const Color(0xFF172238),
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(18),
                          topRight: const Radius.circular(18),
                          bottomLeft: Radius.circular(isUser ? 18 : 5),
                          bottomRight: Radius.circular(isUser ? 5 : 18),
                        ),
                        border: isError
                            ? Border.all(color: Colors.orangeAccent.withAlpha(120))
                            : (isUser ? null : Border.all(color: Colors.white10)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(
                            message.content,
                            style: TextStyle(
                              fontSize: 15,
                              height: 1.45,
                              color: isError ? Colors.orangeAccent : null,
                            ),
                          ),
                          if (!isUser && !isError)
                            Align(
                              alignment: Alignment.centerRight,
                              child: IconButton(
                                visualDensity: VisualDensity.compact,
                                tooltip: 'Read aloud',
                                onPressed: () => _speak(message.content),
                                icon: const Icon(Icons.volume_up_outlined, size: 18, color: Colors.white60),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              decoration: const BoxDecoration(
                color: Color(0xFF0B1020),
                border: Border(top: BorderSide(color: Colors.white10)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: _listening ? 'Stop listening' : 'Voice input',
                    onPressed: _toggleVoiceInput,
                    icon: Icon(_listening ? Icons.mic : Icons.mic_none_rounded,
                        color: _listening ? Colors.redAccent : brandBlue),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: 'Message Ronghor AI…',
                        filled: true,
                        fillColor: const Color(0xFF172238),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: [brandPurple, brandBlue]),
                    ),
                    child: IconButton(
                      onPressed: _busy ? null : _send,
                      icon: const Icon(Icons.arrow_upward_rounded, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
