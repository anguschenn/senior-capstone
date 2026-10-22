import 'env_config.dart';

/// Centralized API endpoint URIs derived from environment config.
class ApiConfig {
  ApiConfig._();

  static late final ApiConfig instance;

  static void init() {
    final env = EnvConfig.instance;
    instance = ApiConfig._()
      .._transactionsUri = Uri.parse('${env.backendUrl}/api/transactions')
      .._aiChatUri = Uri.parse('${env.backendUrl}/api/ai/chat')
      .._aiBudgetSuggestUri = Uri.parse(
        '${env.backendUrl}/api/ai/budget_suggest',
      )
      .._aiCategorySuggestUri = Uri.parse(
        '${env.backendUrl}/api/ai/suggest_category',
      )
      .._budgetProgressUri = Uri.parse('${env.backendUrl}/api/budget_progress')
      .._refreshInsightsUri = Uri.parse(
        '${env.backendUrl}/api/refresh_insights',
      );
  }

  late final Uri _transactionsUri;
  late final Uri _aiChatUri;
  late final Uri _aiBudgetSuggestUri;
  late final Uri _aiCategorySuggestUri;
  late final Uri _budgetProgressUri;
  late final Uri _refreshInsightsUri;

  Uri get transactionsUri => _transactionsUri;
  Uri get aiChatUri => _aiChatUri;
  Uri get aiBudgetSuggestUri => _aiBudgetSuggestUri;
  Uri get aiCategorySuggestUri => _aiCategorySuggestUri;

  /// Base URI for GET /api/budget_progress; callers append ?month=YYYY-MM.
  Uri get budgetProgressUri => _budgetProgressUri;

  /// POST: recompute subscriptions, budget alerts and suggestions.
  Uri get refreshInsightsUri => _refreshInsightsUri;
}
