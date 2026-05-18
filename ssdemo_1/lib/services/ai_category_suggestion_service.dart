import 'package:flutter/material.dart';

import '../core/config/supabase_client.dart';
import '../models/ai/ai_models.dart';
import '../models/app_models.dart';
import '../utils/app_helpers.dart';
import 'ai_api_client.dart';

class AiCategorySuggestionService {
  const AiCategorySuggestionService._();
  static const instance = AiCategorySuggestionService._();

  /// Fetches an AI-suggested category for a transaction and shows the approval dialog.
  /// Returns the selected category (either AI suggestion, edited, or null if rejected).
  Future<String?> suggestAndReviewCategory({
    required BuildContext context,
    required AppTransaction transaction,
    required Uri aiBackendUri,
    required String apiKey,
    String? accessToken,
  }) async {
    try {
      final suggestion = await AiApiClient().suggestCategory(
        uri: aiBackendUri.replace(path: '/api/ai/suggest_category'),
        apiKey: apiKey,
        accessToken: accessToken,
        merchantName: transaction.rawMerchantName.isNotEmpty
            ? transaction.rawMerchantName
            : transaction.name,
        transactionName: transaction.name,
        pfcPrimary: transaction.rawPfcPrimary,
        pfcDetailed: transaction.category,
      );

      if (suggestion.suggestedCategory.isEmpty) {
        return null;
      }

      // Show the suggestion dialog
      String? selectedCategory;
      await showAiCategorySuggestionDialog(
        context: context,
        suggestedCategory: suggestion.suggestedCategory,
        transactionName: transaction.name,
        onAccept: (category) {
          selectedCategory = category;
        },
      );

      return selectedCategory;
    } catch (e) {
      // Silently fail if AI suggestion fails
      debugPrint('AI category suggestion error: $e');
      return null;
    }
  }
}
