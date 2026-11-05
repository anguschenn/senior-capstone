import 'dart:js_interop';

@JS('SmartSpendPush.status')
external JSPromise<JSString> _status();

@JS('SmartSpendPush.subscribe')
external JSPromise<JSString> _subscribe(JSString publicKey);

@JS('SmartSpendPush.requestPermission')
external JSPromise<JSString> _requestPermission();

@JS('SmartSpendPush.unsubscribe')
external JSPromise<JSString> _unsubscribe();

Future<String> status() async => (await _status().toDart).toDart;

Future<String> subscribe(String publicKey) async =>
    (await _subscribe(publicKey.toJS).toDart).toDart;

Future<String> requestPermission() async =>
    (await _requestPermission().toDart).toDart;

Future<String> unsubscribe() async => (await _unsubscribe().toDart).toDart;
