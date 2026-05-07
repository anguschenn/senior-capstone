import 'dart:async';
import 'dart:js' as js;

class PlaidLinkLauncher {
  static Future<String?> open(String linkToken) async {
    final completer = Completer<String?>();

    js.context.callMethod('plaidOpenLink', [
      linkToken,
      (String publicToken) {
        if (!completer.isCompleted) completer.complete(publicToken);
      },
      (js.JsObject? error) {
        if (!completer.isCompleted) completer.complete(null);
      },
    ]);

    return completer.future;
  }
}
