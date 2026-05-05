// Conditional import: native platforms use plaid_flutter; web uses a stub.
export 'plaid_link_launcher_stub.dart'
    if (dart.library.io) 'plaid_link_launcher_native.dart';
