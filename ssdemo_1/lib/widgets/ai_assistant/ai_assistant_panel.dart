import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_theme.dart';
import '../../constants/app_constants.dart';
import '../../models/ai/ai_models.dart';
import '../../models/app_models.dart';
import '../../services/ai_api_client.dart';
import '../../services/auth_service.dart';
import '../../services/chat_history_store.dart';
import '../../utils/app_helpers.dart';
import '../common/ui.dart';
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
    this.selectedMonth,
    this.initialPrompt,
    this.contextLabel,
  });

  final Uri chatApiUri;
  final String apiKey;
  final List<AccountOption> accountOptions;
  final String initialAccountId;
  final Map<String, Map<String, dynamic>> spendingSummaryByAccount;

  /// The month (or all-year option) the summaries were built for. When set,
  /// the backend builds the summary itself and only a small context is sent.
  final DateTime? selectedMonth;

  /// Question put in the input box when the panel is opened from a ✦ chip.
  /// It is not sent until the user taps send.
  final String? initialPrompt;

  /// Where the panel was opened from, e.g. "From Budget · Food · October".
  final String? contextLabel;

  @override
  State<AIAssistantPanel> createState() => _AIAssistantPanelState();
}

class _AIAssistantPanelState extends State<AIAssistantPanel> {
  /// Only turns this recent go to the server as context for follow-ups, so
  /// a question from yesterday doesn't steer today's answer.
  static const Duration _followUpWindow = Duration(minutes: 20);
  static const _client = AiApiClient();
  static const _store = ChatHistoryStore.instance;

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
    _controller.text = widget.initialPrompt ?? '';
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

  /// Null without [AIAssistantPanel.selectedMonth]: the full summary is sent.
  Map<String, dynamic>? get _chatContext {
    final month = widget.selectedMonth;
    if (month == null) return null;
    final accountId = _resolvedAccountId;
    AccountOption? option;
    for (final candidate in widget.accountOptions) {
      if (candidate.accountId == accountId) option = candidate;
    }
    final accountIds = accountId == kAllAccountsId
        ? const <String>[]
        : (option?.linkedAccountIds.toList() ?? [accountId]);
    return AiApiClient.chatContext(
      accountIds: accountIds,
      selectedMonth: month,
      allYear: isAllYearOption(month),
      scopeLabel: '${_activeSummary['scope_label'] ?? ''}',
    );
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
        context: _chatContext,
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

  static const _suggestions = [
    'How much did I spend this month?',
    'Where did I overspend?',
    'Am I on track with my budget?',
    'What are my biggest expenses?',
  ];

  String _accountLabel(String id) {
    if (id == kAllAccountsId) return 'Overall (All Accounts)';
    for (final option in widget.accountOptions) {
      if (option.accountId == id) return option.label;
    }
    return id;
  }

  Future<void> _pickScope() async {
    if (_sending) return;
    final picked = await showOptionSheet<String>(
      context: context,
      title: 'Account scope',
      values: [
        kAllAccountsId,
        for (final option in widget.accountOptions) option.accountId,
      ],
      labelOf: _accountLabel,
      selected: _resolvedAccountId,
    );
    if (picked == null || picked == _selectedAccountId) return;
    setState(() {
      _selectedAccountId = picked;
      _turns.clear();
    });
    _loadSavedTurns();
  }

  Widget _buildTurn(_ChatTurn turn) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
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
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: c.raised,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(turn.prompt, style: const TextStyle(fontSize: 14.5)),
            ),
          ),
          const SizedBox(height: 8),

          // Response or loading/error
          if (turn.response == null && turn.error == null)
            const Padding(
              padding: EdgeInsets.fromLTRB(6, 8, 0, 4),
              child: TypingDots(),
            ),

          if (turn.error != null)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                turn.error!,
                style: TextStyle(color: c.bad, fontSize: 12),
              ),
            ),

          if (turn.response != null) AiResponseCard(response: turn.response!),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final media = MediaQuery.of(context);
    final panelHeight = media.size.height * 0.88;

    return AnimatedPadding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      child: Container(
        height: panelHeight,
        decoration: BoxDecoration(
          color: c.background,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 5,
                decoration: BoxDecoration(
                  color: c.line,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 12, 4),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Ask',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.6,
                        ),
                      ),
                    ),
                    // Fades in once there is a chat to clear.
                    AnimatedOpacity(
                      opacity: _turns.isEmpty ? 0 : 1,
                      duration: const Duration(milliseconds: 200),
                      child: TextButton(
                        onPressed: _turns.isEmpty || _sending
                            ? null
                            : _clearChat,
                        child: Text(
                          'Clear',
                          style: TextStyle(color: c.muted, fontSize: 15),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text(
                        'Done',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Flexible(
                      child: Material(
                        color: c.raised,
                        borderRadius: BorderRadius.circular(99),
                        child: InkWell(
                          key: const ValueKey('ai-scope'),
                          borderRadius: BorderRadius.circular(99),
                          onTap: _sending ? null : _pickScope,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.account_balance_wallet_outlined,
                                  size: 15,
                                  color: c.text,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    _accountLabel(_resolvedAccountId),
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  size: 17,
                                  color: c.muted,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.contextLabel != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: StatusPill(
                      label: widget.contextLabel!,
                      background: c.card,
                      foreground: c.muted,
                      icon: Icons.auto_awesome,
                    ),
                  ),
                ),

              // Message list
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  itemCount: _turns.isEmpty ? 1 : _turns.length,
                  itemBuilder: (_, i) {
                    if (_turns.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.only(top: 60),
                        child: Center(
                          child: Text(
                            'Choose Overall or one account above, then ask about your spending.',
                            style: TextStyle(color: c.muted),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    }
                    return _buildTurn(_turns[i]);
                  },
                ),
              ),

              // Suggestions fill the box; nothing is sent until send is tapped.
              // They wrap onto a second line instead of running off the edge.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final s in _suggestions)
                      ActionChip(
                        label: Text(s),
                        labelStyle: TextStyle(fontSize: 13, color: c.text),
                        backgroundColor: c.card,
                        side: BorderSide.none,
                        shape: const StadiumBorder(),
                        visualDensity: VisualDensity.compact,
                        onPressed: _sending
                            ? null
                            : () => setState(() => _controller.text = s),
                      ),
                  ],
                ),
              ),

              // Input
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Focus(
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
                    autofocus: widget.initialPrompt != null,
                    minLines: 1,
                    maxLines: 3,
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(
                      hintText: 'Ask about your spending...',
                      fillColor: c.card,
                      contentPadding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide.none,
                      ),
                      suffixIcon: Padding(
                        padding: const EdgeInsets.all(5),
                        child: IconButton.filled(
                          onPressed: _sending ? null : _sendPrompt,
                          style: IconButton.styleFrom(
                            backgroundColor: c.button,
                            foregroundColor: c.onButton,
                            disabledBackgroundColor: c.raised,
                          ),
                          // Greyed out while waiting; the dots show progress.
                          icon: const Icon(Icons.arrow_upward_rounded),
                        ),
                      ),
                    ),
                    onSubmitted: (_) => _sendPrompt(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
