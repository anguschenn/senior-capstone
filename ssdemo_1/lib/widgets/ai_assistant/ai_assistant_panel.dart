import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../constants/app_constants.dart';
import '../../models/ai/ai_models.dart';
import '../../models/app_models.dart';
import '../../services/ai_api_client.dart';
import '../../services/auth_service.dart';
import '../../services/chat_history_store.dart';
import 'ai_response_card.dart';

/// Single chat turn: user prompt + optional structured response.
class _ChatTurn {
  _ChatTurn({
    required this.prompt,
    this.response,
    this.error,
    DateTime? askedAt,
  }) : askedAt = askedAt ?? DateTime.now();

  final String prompt;
  final AiChatResponse? response;
  final String? error;
  final DateTime askedAt;
}

class AIAssistantPanel extends StatefulWidget {
  const AIAssistantPanel({
    super.key,
    required this.chatApiUri,
    required this.apiKey,
    required this.accountOptions,
    required this.initialAccountId,
    required this.spendingSummaryByAccount,
  });

  final Uri chatApiUri;
  final String apiKey;
  final List<AccountOption> accountOptions;
  final String initialAccountId;
  final Map<String, Map<String, dynamic>> spendingSummaryByAccount;

  @override
  State<AIAssistantPanel> createState() => _AIAssistantPanelState();
}

class _AIAssistantPanelState extends State<AIAssistantPanel> {
  /// Only turns this recent go to the server as context for follow-ups, so
  /// a question from yesterday doesn't steer today's answer.
  static const Duration _followUpWindow = Duration(minutes: 20);
  static const _client = AiApiClient();
  static const _store = ChatHistoryStore.instance;

  /// Debug builds only: which model answers, "local" (Ollama) or "online"
  /// (OpenRouter). Kept across panel openings while the app runs.
  static String _modelSource = 'local';

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_ChatTurn> _turns = [];
  String? _selectedAccountId;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _selectedAccountId =
        widget.spendingSummaryByAccount.containsKey(widget.initialAccountId)
        ? widget.initialAccountId
        : kAllAccountsId;
    _store.removeDeviceCopies();
    _loadSavedTurns();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String? get _userId => AuthService.instance.currentUser?.id;

  /// Shows the saved chat for the current account scope.
  Future<void> _loadSavedTurns() async {
    final userId = _userId;
    if (userId == null) return;
    final accountId = _resolvedAccountId;
    final saved = await _store.load(userId, accountId);
    if (!mounted || accountId != _resolvedAccountId || _turns.isNotEmpty) {
      return;
    }
    setState(() {
      _turns.addAll([
        for (final turn in saved)
          _ChatTurn(
            prompt: turn.prompt,
            response: turn.response,
            askedAt: turn.askedAt,
          ),
      ]);
    });
    _scrollToBottom();
  }

  /// Saves an answered turn; failed ones aren't worth keeping.
  void _saveTurn(_ChatTurn turn) {
    final userId = _userId;
    final response = turn.response;
    if (userId == null || response == null) return;
    _store.add(
      userId,
      _resolvedAccountId,
      SavedChatTurn(
        prompt: turn.prompt,
        response: response,
        askedAt: turn.askedAt,
      ),
    );
  }

  void _clearChat() {
    final userId = _userId;
    if (userId != null) {
      _store.clear(userId, _resolvedAccountId);
    }
    setState(_turns.clear);
  }

  String get _resolvedAccountId {
    final candidate = _selectedAccountId;
    if (candidate != null &&
        widget.spendingSummaryByAccount.containsKey(candidate)) {
      return candidate;
    }
    return kAllAccountsId;
  }

  Map<String, dynamic> get _activeSummary {
    return widget.spendingSummaryByAccount[_resolvedAccountId] ??
        widget.spendingSummaryByAccount[kAllAccountsId] ??
        const <String, dynamic>{};
  }

  List<AiChatMessage> _buildHistoryPayload() {
    final history = <AiChatMessage>[];
    final since = DateTime.now().subtract(_followUpWindow);
    for (final turn in _turns.where((t) => t.askedAt.isAfter(since))) {
      history.add(AiChatMessage(role: 'user', text: turn.prompt));
      final reply = turn.response?.copy;
      if (reply != null && reply.trim().isNotEmpty) {
        history.add(AiChatMessage(role: 'assistant', text: reply));
      }
    }
    if (history.length > 12) {
      return history.sublist(history.length - 12);
    }
    return history;
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
    final historyPayload = _buildHistoryPayload();

    final turn = _ChatTurn(prompt: prompt);
    setState(() {
      _turns.add(turn);
      _sending = true;
    });
    _controller.clear();
    _scrollToBottom();

    try {
      final aiRespRaw = await _client.sendChat(
        uri: widget.chatApiUri,
        apiKey: widget.apiKey,
        accessToken: AuthService.instance.currentAccessToken,
        prompt: prompt,
        history: historyPayload,
        spendingSummary: _activeSummary,
        modelSource: kDebugMode ? _modelSource : null,
      );
      setState(() {
        _turns[_turns.length - 1] = _ChatTurn(
          prompt: prompt,
          response: aiRespRaw,
          askedAt: turn.askedAt,
        );
      });
      _saveTurn(_turns.last);
    } catch (e) {
      setState(() {
        _turns[_turns.length - 1] = _ChatTurn(
          prompt: prompt,
          error: e is AiApiException
              ? e.message
              : 'Failed to reach AI service.',
          askedAt: turn.askedAt,
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

          if (turn.response != null) AiResponseCard(response: turn.response!),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screenH = media.size.height;
    final panelHeight = (screenH * 0.58)
        .clamp(360.0, (screenH * 0.82).clamp(360.0, 620.0))
        .toDouble();

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
                Row(
                  children: [
                    const Icon(Icons.smart_toy_outlined, color: Colors.green),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'AI Assistant',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    // Fades in once there is a chat to clear.
                    AnimatedOpacity(
                      opacity: _turns.isEmpty ? 0 : 1,
                      duration: const Duration(milliseconds: 200),
                      child: TextButton.icon(
                        onPressed: _turns.isEmpty || _sending
                            ? null
                            : _clearChat,
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('Clear chat'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.black54,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                  ],
                ),
                if (kDebugMode) ...[
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'local',
                        icon: Icon(Icons.computer_outlined),
                        label: Text('Local model'),
                      ),
                      ButtonSegment(
                        value: 'online',
                        icon: Icon(Icons.cloud_outlined),
                        label: Text('Online model'),
                      ),
                    ],
                    selected: {_modelSource},
                    showSelectedIcon: false,
                    onSelectionChanged: _sending
                        ? null
                        : (selection) =>
                              setState(() => _modelSource = selection.first),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  'Choose an account scope first, then ask your question.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.black.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _selectedAccountId,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    labelText: 'Account scope',
                  ),
                  items: [
                    const DropdownMenuItem<String>(
                      value: kAllAccountsId,
                      child: Text('Overall (All Accounts)'),
                    ),
                    ...widget.accountOptions.map(
                      (account) => DropdownMenuItem<String>(
                        value: account.accountId,
                        child: Text(account.label),
                      ),
                    ),
                  ],
                  onChanged: _sending
                      ? null
                      : (value) {
                          if (value == null || value == _selectedAccountId) {
                            return;
                          }
                          setState(() {
                            _selectedAccountId = value;
                            _turns.clear();
                          });
                          _loadSavedTurns();
                        },
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
                              'Which account should I use? Choose Overall or a specific account, then ask your question.',
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
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
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
