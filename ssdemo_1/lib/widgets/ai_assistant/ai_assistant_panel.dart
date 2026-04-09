import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Structured AI response — both chat and budget use this shape.
class _AiResponse {
  _AiResponse({
    required this.copy,
    this.insights = const [],
    this.actions = const [],
    this.confidence = 'medium',
    this.contextSource = '',
  });

  final String copy;
  final List<String> insights;
  final List<String> actions;
  final String confidence;
  final String contextSource;

  static const int maxFieldLength = 500;

  static _AiResponse fromJson(Map<String, dynamic> json) {
    return _AiResponse(
      copy: _clamp(json['copy']?.toString() ?? '', maxFieldLength),
      insights: _parseList(json['insights']),
      actions: _parseList(json['actions']),
      confidence: json['confidence']?.toString() ?? 'medium',
      contextSource: json['context_source']?.toString() ?? '',
    );
  }

  static String _clamp(String s, int maxLen) =>
      s.length > maxLen ? '${s.substring(0, maxLen)}…' : s;

  static List<String> _parseList(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<String>()
        .where((s) => s.trim().isNotEmpty)
        .take(3)
        .map((s) => _clamp(s.trim(), 200))
        .toList();
  }
}

/// Single chat turn: user prompt + optional structured response.
class _ChatTurn {
  _ChatTurn({required this.prompt, this.response, this.error});

  final String prompt;
  final _AiResponse? response;
  final String? error;
}

class AIAssistantPanel extends StatefulWidget {
  const AIAssistantPanel({
    super.key,
    required this.chatApiUri,
    required this.apiKey,
    required this.spendingSummary,
  });

  final Uri chatApiUri;
  final String apiKey;
  final Map<String, dynamic> spendingSummary;

  @override
  State<AIAssistantPanel> createState() => _AIAssistantPanelState();
}

class _AIAssistantPanelState extends State<AIAssistantPanel> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_ChatTurn> _turns = [];
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendPrompt() async {
    final prompt = _controller.text.trim();
    if (prompt.isEmpty || _sending) return;

    final turn = _ChatTurn(prompt: prompt);
    setState(() {
      _turns.add(turn);
      _sending = true;
    });
    _controller.clear();
    _scrollToBottom();

    try {
      final response = await http
          .post(
            widget.chatApiUri,
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': widget.apiKey,
            },
            body: jsonEncode({
              'prompt': prompt,
              'spending_summary': widget.spendingSummary,
            }),
          )
          .timeout(const Duration(seconds: 30));

      final parsed =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final aiResp = _AiResponse.fromJson(parsed);
        setState(() {
          _turns[_turns.length - 1] = _ChatTurn(prompt: prompt, response: aiResp);
        });
      } else {
        setState(() {
          _turns[_turns.length - 1] = _ChatTurn(
            prompt: prompt,
            error: (parsed['error'] ?? 'Request failed').toString(),
          );
        });
      }
    } catch (e) {
      setState(() {
        _turns[_turns.length - 1] = _ChatTurn(
          prompt: prompt,
          error: 'Failed to reach AI service.',
        );
      });
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _scrollToBottom();
      }
    }
  }

  Widget _buildTurn(_ChatTurn turn) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // User prompt bubble
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.72,
              ),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(turn.prompt, style: const TextStyle(fontSize: 14)),
            ),
          ),
          const SizedBox(height: 6),

          // Response or loading/error
          if (turn.response == null && turn.error == null)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),

          if (turn.error != null)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                turn.error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ),

          if (turn.response != null) _buildStructuredResponse(turn.response!),
        ],
      ),
    );
  }

  Widget _buildStructuredResponse(_AiResponse resp) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Confidence + source badges
          Row(
            children: [
              _badge(resp.confidence, _confidenceColor(resp.confidence)),
              if (resp.contextSource.isNotEmpty) ...[
                const SizedBox(width: 6),
                _badge(resp.contextSource, Colors.black38),
              ],
            ],
          ),
          const SizedBox(height: 8),

          // Copy (main answer)
          if (resp.copy.isNotEmpty)
            Text(
              resp.copy,
              style: const TextStyle(fontSize: 13.5, height: 1.4),
            ),

          // Insights
          if (resp.insights.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text(
              'Insights',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Colors.black54,
              ),
            ),
            const SizedBox(height: 4),
            ...resp.insights.map(
              (s) => Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('• ', style: TextStyle(fontSize: 13)),
                    Expanded(
                      child: Text(s, style: const TextStyle(fontSize: 13, height: 1.3)),
                    ),
                  ],
                ),
              ),
            ),
          ],

          // Actions
          if (resp.actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text(
              'Actions',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Colors.black54,
              ),
            ),
            const SizedBox(height: 4),
            ...resp.actions.map(
              (s) => Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('→ ', style: TextStyle(fontSize: 13, color: Colors.green)),
                    Expanded(
                      child: Text(s, style: const TextStyle(fontSize: 13, height: 1.3)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  Color _confidenceColor(String confidence) {
    switch (confidence) {
      case 'high':
        return Colors.green;
      case 'medium':
        return Colors.orange;
      case 'low':
        return Colors.redAccent;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screenH = media.size.height;
    final panelHeight =
        (screenH * 0.58).clamp(360.0, (screenH * 0.82).clamp(360.0, 620.0)).toDouble();

    return SafeArea(
      child: AnimatedPadding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        child: Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(24),
          ),
          child: SizedBox(
            height: panelHeight,
            child: Column(
              mainAxisSize: MainAxisSize.max,
              children: [
                // Header
                const Row(
                  children: [
                    Icon(Icons.smart_toy_outlined, color: Colors.green),
                    SizedBox(width: 10),
                    Text(
                      'AI Assistant',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Message list
                Expanded(
                  child: ListView.builder(
                    controller: _scrollController,
                    itemCount: _turns.isEmpty ? 1 : _turns.length,
                    itemBuilder: (_, i) {
                      if (_turns.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.only(top: 80),
                          child: Center(
                            child: Text(
                              'Ask me about your spending, budgets, or savings goals.',
                              style: TextStyle(color: Colors.black45),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        );
                      }
                      return _buildTurn(_turns[i]);
                    },
                  ),
                ),

                const SizedBox(height: 10),

                // Input
                Focus(
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.enter &&
                        !HardwareKeyboard.instance.isShiftPressed) {
                      _sendPrompt();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    controller: _controller,
                    minLines: 1,
                    maxLines: 3,
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(
                      hintText: 'Ask about your spending...',
                      prefixIcon: const Icon(Icons.chat_bubble_outline),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        onPressed: _sending ? null : _sendPrompt,
                        icon: _sending
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.send),
                      ),
                    ),
                    onSubmitted: (_) => _sendPrompt(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
