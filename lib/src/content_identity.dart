import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'models.dart';
import 'runner.dart';

typedef ContentIdentity = ({String token, ContentAvailability availability});

/// Hash and inspect bounded content without expanding it into a boxed byte list
/// or doing a large synchronous digest on an in-process host's UI isolate.
/// Only bytes and strings cross the isolate boundary; no repository resources,
/// process callbacks, or cancellation subscriptions belong to the worker.
Future<ContentIdentity> identifyContent(
  List<int> bytes, {
  required String mode,
  String? tokenPrefix,
  GitCancellation? cancellation,
}) async {
  cancellation?.check();
  final result = bytes.length < 64 * 1024
      ? _identify(bytes, mode, tokenPrefix)
      : await _backgroundIdentify(bytes, mode, tokenPrefix);
  cancellation?.check();
  return result;
}

// Keep the launch closure outside the caller's scope so its context cannot
// capture the cancellation completer or any of its listeners.
Future<ContentIdentity> _backgroundIdentify(
  List<int> bytes,
  String mode,
  String? tokenPrefix,
) => Isolate.run(() => _identify(bytes, mode, tokenPrefix));

ContentIdentity _identify(List<int> bytes, String mode, String? tokenPrefix) {
  var availability = mode == '120000'
      ? ContentAvailability.symlink
      : ContentAvailability.present;
  if (bytes.contains(0)) {
    availability = ContentAvailability.binary;
  } else {
    try {
      utf8.decode(bytes);
    } on FormatException {
      availability = ContentAvailability.binary;
    }
  }
  var token = '';
  if (tokenPrefix != null) {
    final result = _DigestResult();
    final sink = sha256.startChunkedConversion(result);
    sink.add(utf8.encode(tokenPrefix));
    sink.add(bytes);
    sink.close();
    token = result.digest!.toString();
  }
  return (token: token, availability: availability);
}

final class _DigestResult implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest value) => digest = value;
  @override
  void close() {}
}
