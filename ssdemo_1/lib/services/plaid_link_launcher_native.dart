import 'dart:async';

import 'package:plaid_flutter/plaid_flutter.dart';

class PlaidLinkLauncher {
  /// Opens Plaid Link with the given link token.
  /// Returns the public_token on success, or null if the user exits.
  static Future<String?> open(String linkToken) async {
    final completer = Completer<String?>();

    final successSub = PlaidLink.onSuccess.listen((LinkSuccess event) {
      if (!completer.isCompleted) completer.complete(event.publicToken);
    });

    final exitSub = PlaidLink.onExit.listen((LinkExit event) {
      if (!completer.isCompleted) completer.complete(null);
    });

    try {
      await PlaidLink.open(
        configuration: LinkTokenConfiguration(token: linkToken),
      );
      return await completer.future;
    } finally {
      await successSub.cancel();
      await exitSub.cancel();
    }
  }
}
