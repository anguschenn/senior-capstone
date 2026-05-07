// Conditional import: native iOS/Android uses plaid_flutter; web uses Plaid.js.
export 'plaid_link_launcher_stub.dart'
    if (dart.library.io) 'plaid_link_launcher_native.dart'
    if (dart.library.html) 'plaid_link_launcher_web.dart';
