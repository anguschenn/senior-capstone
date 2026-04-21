import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../constants/app_constants.dart';
import '../../models/ai/ai_models.dart';
import '../../models/app_models.dart';
import '../../services/ai_api_client.dart';
import 'ai_response_card.dart';

/// Single chat turn: user prompt + optional structured response.
class _ChatTurn {
  _ChatTurn({required this.prompt, this.response, this.error});

  final String prompt;
  final AiChatResponse? response;
  final String? error;
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
  static const int _maxCachedTurns = 6;
  static const Duration _cacheTtl = Duration(minutes: 20);
  static final Map<String, List<_ChatTurn>> _cachedTurnsByKey =
      <String, List<_ChatTurn>>{};
  static final Map<String, DateTime> _cachedAtByKey = <String, DateTime>{};
  static const _client = AiApiClient();

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
    _restoreTurnsFromCache();
  }

  @override
  void dispose() {
    _persistTurnsToCache();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _restoreTurnsFromCache() {
    final key = _cacheKey;
    final cachedTurns = _cachedTurnsByKey[key];
    final cachedAt = _cachedAtByKey[key];
    if (cachedTurns == null || cachedAt == null) return;
    if (DateTime.now().difference(cachedAt) > _cacheTtl) {
      _cachedTurnsByKey.remove(key);
      _cachedAtByKey.remove(key);
      return;
    }
    _turns
      ..clear()
      ..addAll(cachedTurns);
    _scrollToBottom();
  }

  void _persistTurnsToCache() {
    final key = _cacheKey;
    final successfulTurns = _turns
        .where((turn) => turn.response != null)
        .toList();
    final start = successfulTurns.length > _maxCachedTurns
        ? successfulTurns.length - _maxCachedTurns
        : 0;
    _cachedTurnsByKey[key] = successfulTurns.sublist(start);
    _cachedAtByKey[key] = DateTime.now();
  }

  String get _resolvedAccountId {
    final candidate = _selectedAccountId;
    if (candidate != null &&
        widget.spendingSummaryByAccount.containsKey(candidate)) {
      return candidate;
    }
    return kAllAccountsId;
  }

  String get _cacheKey => '${widget.chatApiUri.origin}|$_resolvedAccountId';

  Map<String, dynamic> get _activeSummary {
    return widget.spendingSummaryByAccount[_resolvedAccountId] ??
        widget.spendingSummaryByAccount[kAllAccountsId] ??
        const <String, dynamic>{};
  }

  List<AiChatMessage> _buildHistoryPayload() {
    final history = <AiChatMessage>[];
    for (final turn in _turns) {
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
    _persistTurnsToCache();
    _controller.clear();
    _scrollToBottom();

    try {
      final aiRespRaw = await _client.sendChat(
        uri: widget.chatApiUri,
        apiKey: widget.apiKey,
        prompt: prompt,
        history: historyPayload,
        spendingSummary: _activeSummary,
      );
      final localOverride = _localAmountOverride(prompt, _activeSummary);
      final aiResp = localOverride == null
          ? aiRespRaw
          : AiChatResponse(
              copy: localOverride,
              insights: aiRespRaw.insights,
              actions: aiRespRaw.actions,
              confidence: aiRespRaw.confidence,
              citations: aiRespRaw.citations,
              contextSource: aiRespRaw.contextSource,
              intent: aiRespRaw.intent,
            );
      setState(() {
        _turns[_turns.length - 1] = _ChatTurn(prompt: prompt, response: aiResp);
      });
      _persistTurnsToCache();
    } catch (e) {
      setState(() {
        _turns[_turns.length - 1] = _ChatTurn(
          prompt: prompt,
          error: e is AiApiException
              ? e.message
              : 'Failed to reach AI service.',
        );
      });
      _persistTurnsToCache();
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _scrollToBottom();
      }
    }
  }

  bool _asksAmount(String prompt) {
    final text = prompt.toLowerCase();
    if (text.contains('how much') ||
        text.contains('what did i spend') ||
        text.contains('amount') ||
        text.contains('total spent') ||
        text.contains('spending total')) {
      return true;
    }

    if (RegExp(r'(\$|usd|dollar|dollars)').hasMatch(text)) {
      return true;
    }

    final hasMoneyVerb = RegExp(
      r'\b(spend|spent|spending|expense|expenses|cost|costs|pay|paid)\b',
    ).hasMatch(text);
    final hasTimeRef = _extractDateKey(prompt) != null ||
        _extractMonthKey(prompt, DateTime.now().year) != null ||
        RegExp(r'\b20\d{2}\b').hasMatch(text) ||
        text.contains('this month') ||
        text.contains('last month') ||
        text.contains('this year') ||
        text.contains('last 30 days') ||
        text.contains('30 days');

    return hasMoneyVerb && hasTimeRef;
  }

  bool _asksMonthRanking(String prompt) {
    final text = prompt.toLowerCase();
    final hasMonthWord = text.contains('month') || text.contains('months');
    final hasRankingWord = text.contains('which') ||
        text.contains('highest') ||
        text.contains('top') ||
        text.contains('most');
    final hasSpendingWord = text.contains('spend') ||
        text.contains('spent') ||
        text.contains('spending') ||
        text.contains('expense') ||
        text.contains('expenses');
    return hasMonthWord && hasRankingWord && hasSpendingWord;
  }

  String? _extractMonthKey(String prompt, int defaultYear) {
    final text = prompt.toLowerCase();
    final direct = RegExp(r'\b(20\d{2})-(\d{2})\b').firstMatch(text);
    if (direct != null) {
      return '${direct.group(1)}-${direct.group(2)}';
    }
    final ym = RegExp(r'\b(20\d{2})[/-](\d{1,2})\b').firstMatch(text);
    if (ym != null) {
      final year = int.tryParse(ym.group(1) ?? '');
      final month = int.tryParse(ym.group(2) ?? '');
      if (year != null && month != null && month >= 1 && month <= 12) {
        return '$year-${month.toString().padLeft(2, '0')}';
      }
    }
    const monthMap = <String, int>{
      'january': 1,
      'february': 2,
      'march': 3,
      'april': 4,
      'may': 5,
      'june': 6,
      'july': 7,
      'august': 8,
      'september': 9,
      'october': 10,
      'november': 11,
      'december': 12,
      'jan': 1,
      'feb': 2,
      'mar': 3,
      'apr': 4,
      'jun': 6,
      'jul': 7,
      'aug': 8,
      'sep': 9,
      'sept': 9,
      'oct': 10,
      'nov': 11,
      'dec': 12,
    };
    for (final entry in monthMap.entries) {
      if (RegExp('\\b${entry.key}\\b').hasMatch(text)) {
        return '$defaultYear-${entry.value.toString().padLeft(2, '0')}';
      }
    }
    return null;
  }

  String? _extractDateKey(String prompt) {
    final text = prompt.toLowerCase();
    final m = RegExp(r'\b(20\d{2}-\d{2}-\d{2})\b').firstMatch(text);
    return m?.group(1);
  }

  String? _localAmountOverride(String prompt, Map<String, dynamic> summary) {
    final lower = prompt.toLowerCase();
    final scopeLabel = (summary['scope_label'] ?? 'this scope').toString();
    final annual = (summary['annual_summary'] is Map)
        ? (summary['annual_summary'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final annualTotals = (annual['totals'] is Map)
        ? (annual['totals'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final timeAnchor = (summary['time_anchor'] is Map)
        ? (summary['time_anchor'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final monthIndex = (summary['month_index'] is Map)
        ? (summary['month_index'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final dayIndex = (summary['day_index_recent'] is Map)
        ? (summary['day_index_recent'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final rankings = (summary['rankings'] is Map)
        ? (summary['rankings'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};

    if (_asksMonthRanking(prompt)) {
      final topMonths = (rankings['highest_spending_months'] is List)
          ? (rankings['highest_spending_months'] as List)
          : const [];
      final entries = <String>[];
      for (final item in topMonths) {
        if (item is! Map) continue;
        final row = item.cast<String, dynamic>();
        final month = (row['month'] ?? '').toString();
        final amount = ((row['expenses'] as num?) ?? 0).toDouble();
        if (month.isEmpty) continue;
        entries.add('$month (\$${amount.toStringAsFixed(2)})');
        if (!lower.contains('months') && entries.isNotEmpty) {
          break;
        }
        if (entries.length >= 3) break;
      }
      if (entries.isEmpty) {
        final sorted = monthIndex.entries.where((e) => e.value is Map).toList()
          ..sort((a, b) {
            final av = (a.value as Map).cast<String, dynamic>();
            final bv = (b.value as Map).cast<String, dynamic>();
            final aa = ((av['expenses'] as num?) ?? 0).toDouble();
            final bb = ((bv['expenses'] as num?) ?? 0).toDouble();
            return bb.compareTo(aa);
          });
        for (final e in sorted.take(lower.contains('months') ? 3 : 1)) {
          final row = (e.value as Map).cast<String, dynamic>();
          final amount = ((row['expenses'] as num?) ?? 0).toDouble();
          entries.add('${e.key} (\$${amount.toStringAsFixed(2)})');
        }
      }
      if (entries.isEmpty) return null;
      if (lower.contains('months')) {
        return 'Highest spending months for $scopeLabel: ${entries.join(', ')}.';
      }
      return 'Highest spending month for $scopeLabel: ${entries.first}.';
    }

    if (!_asksAmount(prompt)) return null;

    final dateKey = _extractDateKey(prompt);
    if (dateKey != null) {
      final row = (dayIndex[dateKey] is Map)
          ? (dayIndex[dateKey] as Map).cast<String, dynamic>()
          : const <String, dynamic>{};
      final amount = ((row['expenses'] as num?) ?? 0).toDouble();
      return 'For $dateKey, total expenses for $scopeLabel are \$${amount.toStringAsFixed(2)}.';
    }

    final selectedYear =
        ((timeAnchor['selected_year'] as num?) ??
                (annual['year'] as num?) ??
                DateTime.now().year)
            .toInt();
    final monthKey = _extractMonthKey(prompt, selectedYear);
    if (monthKey != null) {
      final selectedMonthKey = (timeAnchor['selected_month'] ?? '').toString();
      if (monthKey == selectedMonthKey &&
          (timeAnchor['selected_month_expenses'] as num?) != null) {
        final amount = (timeAnchor['selected_month_expenses'] as num)
            .toDouble();
        return 'For $monthKey, total expenses for $scopeLabel are \$${amount.toStringAsFixed(2)}.';
      }
      final row = (monthIndex[monthKey] is Map)
          ? (monthIndex[monthKey] as Map).cast<String, dynamic>()
          : const <String, dynamic>{};
      final amount = ((row['expenses'] as num?) ?? 0).toDouble();
      return 'For $monthKey, total expenses for $scopeLabel are \$${amount.toStringAsFixed(2)}.';
    }

    if (lower.contains('this year') || lower.contains('year')) {
      final year = ((annual['year'] as num?) ?? selectedYear).toInt();
      final amount = ((annualTotals['expenses_year'] as num?) ?? 0).toDouble();
      return 'For $year, total expenses for $scopeLabel are \$${amount.toStringAsFixed(2)}.';
    }
    return null;
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
                const Row(
                  children: [
                    Icon(Icons.smart_toy_outlined, color: Colors.green),
                    SizedBox(width: 10),
                    Text(
                      'AI Assistant',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
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
                          _restoreTurnsFromCache();
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
