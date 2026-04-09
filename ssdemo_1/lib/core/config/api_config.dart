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
      .._aiBudgetSuggestUri =
          Uri.parse('${env.backendUrl}/api/ai/budget_suggest');
  }

  late final Uri _transactionsUri;
  late final Uri _aiChatUri;
  late final Uri _aiBudgetSuggestUri;

  Uri get transactionsUri => _transactionsUri;
  Uri get aiChatUri => _aiChatUri;
  Uri get aiBudgetSuggestUri => _aiBudgetSuggestUri;
}
