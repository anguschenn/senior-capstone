import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/config/api_config.dart';
import '../core/config/env_config.dart';
import 'auth_service.dart';
import 'push_notifications_stub.dart'
    if (dart.library.js_interop) 'push_notifications_web.dart'
    as browser;

class BrowserPushStatus {
  const BrowserPushStatus({
    required this.supported,
    required this.permission,
    required this.subscribed,
  });

  final bool supported;
  final String permission;
  final bool subscribed;
}

class PushNotificationService {
  const PushNotificationService._();
  static const instance = PushNotificationService._();

  Map<String, String> _headers({bool json = false}) {
    final token = AuthService.instance.currentAccessToken;
    if (token == null || token.isEmpty) {
      throw StateError(
        'Sign in before changing browser notification settings.',
      );
    }
    return {
      'x-api-key': EnvConfig.instance.backendApiKey,
      'Authorization': 'Bearer $token',
      if (json) 'Content-Type': 'application/json',
    };
  }

  Future<BrowserPushStatus> status() async {
    final decoded = _decode(await browser.status());
    return BrowserPushStatus(
      supported: decoded['supported'] == true,
      permission: decoded['permission'] as String? ?? 'default',
      subscribed: decoded['subscribed'] == true,
    );
  }

  Future<void> enable() async {
    final permission = _decode(await browser.requestPermission());
    if (permission['supported'] != true) {
      throw StateError('This browser does not support push notifications.');
    }
    if (permission['permission'] != 'granted') {
      throw StateError(
        permission['permission'] == 'denied'
            ? 'Chrome has blocked notifications for this site. Allow them in the site settings, then try again.'
            : 'Chrome did not grant notification permission.',
      );
    }

    final response = await http
        .get(ApiConfig.instance.pushConfigUri, headers: _headers())
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError(
        _responseMessage(response, 'Could not load push settings.'),
      );
    }
    final config = _decode(response.body);
    if (config['enabled'] != true ||
        config['vapid_public_key'] is! String ||
        (config['vapid_public_key'] as String).isEmpty) {
      throw StateError(
        'Browser notifications are not configured on the backend yet.',
      );
    }

    final result = _decode(
      await browser.subscribe(config['vapid_public_key'] as String),
    );
    if (result['supported'] != true) {
      throw StateError('This browser does not support push notifications.');
    }
    if (result['permission'] != 'granted') {
      throw StateError(
        result['permission'] == 'denied'
            ? 'Chrome has blocked notifications for this site. Allow them in the site settings, then try again.'
            : 'Chrome did not grant notification permission.',
      );
    }
    final subscription = result['subscription'];
    if (subscription is! Map<String, dynamic>) {
      throw StateError('Chrome did not return a push subscription.');
    }

    final save = await http
        .post(
          ApiConfig.instance.pushSubscriptionsUri,
          headers: _headers(json: true),
          body: jsonEncode({'subscription': subscription}),
        )
        .timeout(const Duration(seconds: 15));
    if (save.statusCode != 201 && save.statusCode != 200) {
      throw StateError(
        _responseMessage(save, 'Could not save this browser subscription.'),
      );
    }
  }

  Future<void> disable() async {
    final current = _decode(await browser.status());
    final subscription = current['subscription'];
    if (subscription is Map<String, dynamic>) {
      final endpoint = subscription['endpoint'];
      if (endpoint is String && endpoint.isNotEmpty) {
        final response = await http
            .delete(
              ApiConfig.instance.pushSubscriptionsUri,
              headers: _headers(json: true),
              body: jsonEncode({'endpoint': endpoint}),
            )
            .timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) {
          throw StateError(
            _responseMessage(response, 'Could not remove this subscription.'),
          );
        }
      }
    }
    await browser.unsubscribe();
  }

  Map<String, dynamic> _decode(String body) {
    final value = jsonDecode(body);
    if (value is! Map<String, dynamic>) {
      throw const FormatException(
        'The push service returned an invalid response.',
      );
    }
    return value;
  }

  String _responseMessage(http.Response response, String fallback) {
    try {
      final body = _decode(response.body);
      final message = body['error'];
      if (message is String && message.isNotEmpty) return message;
    } on FormatException {
      // Use the safe, local fallback for non-JSON responses.
    }
    return fallback;
  }
}
