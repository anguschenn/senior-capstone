import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/ai/ai_models.dart';

class AiApiException implements Exception {
  const AiApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AiApiClient {
  const AiApiClient();

  Future<AiChatResponse> sendChat({
    required Uri uri,
    required String apiKey,
    String? accessToken,
    required String prompt,
    required List<AiChatMessage> history,
    required Map<String, dynamic> spendingSummary,
  }) async {
    final parsed = await _postJson(
      uri: uri,
      apiKey: apiKey,
      accessToken: accessToken,
      body: {
        'prompt': prompt,
        'history': history.map((item) => item.toJson()).toList(),
        'spending_summary': spendingSummary,
      },
    );
    return AiChatResponse.fromJson(parsed);
  }

  Future<AiBudgetSuggestionResponse> fetchBudgetSuggestions({
    required Uri uri,
    required String apiKey,
    String? accessToken,
    required Map<String, dynamic> spendingSummary,
    required List<Map<String, dynamic>> budgetProgress,
    required String viewMode,
    bool simplified = false,
  }) async {
    final parsed = await _postJson(
      uri: uri,
      apiKey: apiKey,
      accessToken: accessToken,
      body: {
        'spending_summary': spendingSummary,
        'budget_progress': budgetProgress,
        'view_mode': viewMode,
        'simplified': simplified,
      },
    );
    return AiBudgetSuggestionResponse.fromJson(parsed);
  }

  Future<AiCategorySuggestionResponse> suggestCategory({
    required Uri uri,
    required String apiKey,
    String? accessToken,
    required String merchantName,
    required String transactionName,
    String pfcPrimary = '',
    String pfcDetailed = '',
  }) async {
    final parsed = await _postJson(
      uri: uri,
      apiKey: apiKey,
      accessToken: accessToken,
      body: {
        'merchant_name': merchantName,
        'transaction_name': transactionName,
        'pfc_primary': pfcPrimary,
        'pfc_detailed': pfcDetailed,
      },
    );
    return AiCategorySuggestionResponse.fromJson(parsed);
  }

  Future<Map<String, dynamic>> _postJson({
    required Uri uri,
    required String apiKey,
    String? accessToken,
    required Map<String, dynamic> body,
  }) async {
    try {
      final headers = <String, String>{
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
      };
      final token = accessToken?.trim() ?? '';
      if (token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
      final response = await http
          .post(uri, headers: headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 30));

      final rawBody = utf8.decode(response.bodyBytes);
      final parsed = _decodeJson(
        rawBody,
        response.statusCode,
        response.headers['content-type'],
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AiApiException((parsed['error'] ?? 'Request failed').toString());
      }
      return parsed;
    } on TimeoutException {
      throw AiApiException(
        'AI request timed out (30s). Ensure backend is running at ${uri.origin}.',
      );
    } on SocketException {
      throw AiApiException(
        'Cannot reach AI backend at ${uri.origin}. Start backend and retry.',
      );
    } on http.ClientException catch (e) {
      throw AiApiException(
        'Network error while reaching AI backend: ${e.message}',
      );
    }
  }

  Map<String, dynamic> _decodeJson(
    String rawBody,
    int statusCode,
    String? contentType,
  ) {
    try {
      return jsonDecode(rawBody) as Map<String, dynamic>;
    } catch (_) {
      final preview = rawBody.length > 180
          ? '${rawBody.substring(0, 180)}...'
          : rawBody;
      throw AiApiException(
        'Expected JSON but got ${contentType ?? 'unknown'} (HTTP $statusCode). Body preview: $preview',
      );
    }
  }
}
