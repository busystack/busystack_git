import 'dart:convert';

/// Dart's UTF-8 decoder consumes a leading BOM. Git content and Linux names
/// must round-trip their bytes, including that leading code point.
String decodeGitUtf8(List<int> bytes, {bool allowMalformed = false}) {
  final text = utf8.decode(bytes, allowMalformed: allowMalformed);
  return bytes.length >= 3 &&
          bytes[0] == 0xef &&
          bytes[1] == 0xbb &&
          bytes[2] == 0xbf
      ? '\uFEFF$text'
      : text;
}
