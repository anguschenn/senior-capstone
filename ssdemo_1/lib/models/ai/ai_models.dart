class AiChatMessage {
  const AiChatMessage({required this.role, required this.text});

  final String role;
  final String text;

  Map<String, String> toJson() => {'role': role, 'text': text};
}

class AiChatResponse {
  const AiChatResponse({
    required this.copy,
    this.insights = const [],
    this.actions = const [],
    this.citations = const [],
    this.contextSource = '',
    this.intent = '',
  });

  final String copy;
  final List<String> insights;
  final List<String> actions;
  final List<String> citations;
  final String contextSource;
  final String intent;

  factory AiChatResponse.fromJson(Map<String, dynamic> json) {
    final mainText = (json['reply'] ?? json['copy'] ?? '').toString();
    final insights = _parseStringList(json['insights'] ?? json['why']);
    final actions = _parseStringList(json['actions'] ?? json['next_actions']);
    final citations = _parseStringList(json['citations']);
    return AiChatResponse(
      copy: _normalizeMainText(mainText),
      insights: insights,
      actions: actions,
      citations: citations,
      contextSource: json['context_source']?.toString() ?? '',
      intent: json['intent']?.toString() ?? '',
    );
  }
}

class AiBudgetAlert {
  const AiBudgetAlert({
    required this.category,
    required this.severity,
    required this.reason,
  });

  final String category;
  final String severity;
  final String reason;

  factory AiBudgetAlert.fromJson(Map<String, dynamic> json) {
    return AiBudgetAlert(
      category: (json['category'] ?? 'Unknown').toString(),
      severity: (json['severity'] ?? json['level'] ?? 'med').toString(),
      reason: (json['reason'] ?? json['message'] ?? '').toString(),
    );
  }
}

class AiBudgetAction {
  const AiBudgetAction({
    required this.category,
    required this.type,
    required this.target,
    required this.why,
  });

  final String category;
  final String type;
  final String target;
  final String why;

  factory AiBudgetAction.fromJson(Map<String, dynamic> json) {
    return AiBudgetAction(
      category: (json['category'] ?? json['id'] ?? 'Unknown').toString(),
      type: (json['type'] ?? 'monitor').toString(),
      target: (json['target'] ?? '').toString(),
      why: (json['why'] ?? json['label'] ?? '').toString(),
    );
  }
}

class AiBudgetSuggestionResponse {
  const AiBudgetSuggestionResponse({
    required this.copy,
    required this.alerts,
    required this.actions,
    required this.confidence,
    required this.contextSource,
  });

  final String copy;
  final List<AiBudgetAlert> alerts;
  final List<AiBudgetAction> actions;
  final String confidence;
  final String contextSource;

  factory AiBudgetSuggestionResponse.fromJson(Map<String, dynamic> json) {
    final container = (json['suggestions'] is Map<String, dynamic>)
        ? json['suggestions'] as Map<String, dynamic>
        : json;
    var confidence = (container['confidence'] ?? '').toString().trim();
    if (confidence.isNotEmpty &&
        confidence != 'low' &&
        confidence != 'medium' &&
        confidence != 'high') {
      final numericConfidence = _toDouble(container['confidence']);
      if (numericConfidence > 0) {
        if (numericConfidence >= 0.75) {
          confidence = 'high';
        } else if (numericConfidence >= 0.45) {
          confidence = 'medium';
        } else {
          confidence = 'low';
        }
      } else {
        confidence = '';
      }
    }
    return AiBudgetSuggestionResponse(
      copy: _normalizeMainText((container['copy'] ?? '').toString()),
      alerts: _parseObjectList(container['alerts'], AiBudgetAlert.fromJson),
      actions: _parseObjectList(container['actions'], AiBudgetAction.fromJson),
      confidence: confidence,
      contextSource:
          (json['context_source'] ?? container['context_source'] ?? '')
              .toString(),
    );
  }
}

String _normalizeMainText(String value) {
  var text = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  text = text.replaceFirst(RegExp("^[`\"']+"), '');
  text = text.replaceFirst(RegExp("[`\"']+\$"), '');
  if (text.startsWith('{')) {
    final copyKeyIndex = text.indexOf('"copy"');
    if (copyKeyIndex >= 0) {
      final colonIndex = text.indexOf(':', copyKeyIndex);
      if (colonIndex >= 0) {
        var tail = text.substring(colonIndex + 1).trimLeft();
        if (tail.startsWith('"')) {
          tail = tail.substring(1);
          final endQuote = tail.indexOf('"');
          text = endQuote >= 0 ? tail.substring(0, endQuote) : tail;
        }
      }
    }
  }
  return text
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\t', '\t')
      .replaceAll(r'\"', '"')
      .trim();
}

List<String> _parseStringList(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<String>()
      .where((s) => s.trim().isNotEmpty)
      .take(6)
      .map((s) => s.trim())
      .toList();
}

double _toDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) {
    final parsed = double.tryParse(value.trim());
    if (parsed != null) return parsed;
  }
  return 0.0;
}

List<T> _parseObjectList<T>(
  dynamic raw,
  T Function(Map<String, dynamic>) fromJson,
) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((item) => fromJson(item.cast<String, dynamic>()))
      .toList();
}
