Future<String> status() async =>
    '{"supported":false,"permission":"unsupported"}';

Future<String> requestPermission() async =>
    '{"supported":false,"permission":"unsupported"}';

Future<String> subscribe(String publicKey) async =>
    '{"supported":false,"permission":"unsupported"}';

Future<String> unsubscribe() async => '{"unsubscribed":true}';
