class PlaidLinkLauncher {
  /// Non-native fallback: return null so the caller can skip Link and use its fallback flow.
  static Future<String?> open(String linkToken) async => null;
}
