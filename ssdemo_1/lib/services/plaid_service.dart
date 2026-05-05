import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/config/env_config.dart';
import 'auth_service.dart';
import 'plaid_link_launcher.dart';

class PlaidService {
  const PlaidService._();
  static const instance = PlaidService._();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'x-api-key': EnvConfig.instance.backendApiKey,
        if (AuthService.instance.currentAccessToken != null)
          'Authorization': 'Bearer ${AuthService.instance.currentAccessToken}',
      };

  Future<String> createLinkToken() async {
    final uri = Uri.parse('${EnvConfig.instance.backendUrl}/api/create_link_token');
    final response = await http.post(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw Exception('Failed to create link token: ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final token = body['link_token'] as String?;
    if (token == null || token.isEmpty) {
      throw Exception('No link_token in response: ${response.body}');
    }
    return token;
  }

  Future<void> exchangePublicToken(String publicToken) async {
    final uri = Uri.parse('${EnvConfig.instance.backendUrl}/api/set_access_token');
    final response = await http.post(
      uri,
      headers: _headers,
      body: jsonEncode({'public_token': publicToken}),
    );
    if (response.statusCode != 200) {
      throw Exception('Token exchange failed: ${response.body}');
    }
  }

  /// Opens Plaid Link and returns the public_token, or null if unsupported/cancelled.
  Future<String?> openLink() async {
    final linkToken = await createLinkToken();
    return PlaidLinkLauncher.open(linkToken);
  }
}
