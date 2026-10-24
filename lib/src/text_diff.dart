import 'dart:convert';
import 'dart:typed_data';
import 'models.dart';

enum TextEditKind { equal, remove, add }

final class TextEdit {
  const TextEdit(this.kind, this.text, this.oldLine, this.newLine);
  final TextEditKind kind;

  /// Includes the actual line terminator, if present.
  final String text;
  final int? oldLine, newLine;
}

final class TextDiff {
  const TextDiff(this.edits);
  final List<TextEdit> edits;
  List<int> get changedIndices => [
    for (var i = 0; i < edits.length; i++)
      if (edits[i].kind != TextEditKind.equal) i,
  ];

  /// Build a new index blob directly from exact lines, without changing disk.
  Uint8List select(Set<int> selected, {bool exclude = false}) {
    final out = StringBuffer();
    for (var i = 0; i < edits.length; i++) {
      final edit = edits[i];
      final chosen = exclude ? !selected.contains(i) : selected.contains(i);
      if (edit.kind == TextEditKind.equal ||
          edit.kind == TextEditKind.add && chosen ||
          edit.kind == TextEditKind.remove && !chosen)
        out.write(edit.text);
    }
    return Uint8List.fromList(utf8.encode(out.toString()));
  }
}

List<String> exactLines(String text) {
  final result = <String>[];
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 10) {
      result.add(text.substring(start, i + 1));
      start = i + 1;
    }
  }
  if (start < text.length) result.add(text.substring(start));
  return result;
}

/// Myers' shortest edit script. Work is bounded independently of UI settings.
TextDiff computeTextDiff(
  String left,
  String right, {
  int maximumWork = 2000000,
}) {
  return computeTokenDiff(
    exactLines(left),
    exactLines(right),
    maximumWork: maximumWork,
  );
}

/// The same bounded edit script for display-only word tokens. Token positions
/// use the line-number fields; staging continues to use exact original lines.
TextDiff computeTokenDiff(
  List<String> a,
  List<String> b, {
  int maximumWork = 2000000,
}) {
  final n = a.length, m = b.length;
  if (n + m > 100000) throw const GitException(GitErrorCode.outputLimit);
  var v = <int, int>{1: 0};
  final trace = <Map<int, int>>[];
  var work = 0;
  for (var d = 0; d <= n + m; d++) {
    trace.add(Map.of(v));
    for (var k = -d; k <= d; k += 2) {
      if (++work > maximumWork)
        throw const GitException(GitErrorCode.outputLimit);
      var x = k == -d || k != d && (v[k - 1] ?? -1) < (v[k + 1] ?? -1)
          ? v[k + 1] ?? 0
          : (v[k - 1] ?? 0) + 1;
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[k] = x;
      if (x >= n && y >= m) {
        final reverse = <TextEdit>[];
        var bx = n, by = m;
        for (var depth = d; depth >= 0; depth--) {
          final previous = trace[depth];
          final diagonal = bx - by;
          final pk =
              diagonal == -depth ||
                  diagonal != depth &&
                      (previous[diagonal - 1] ?? -1) <
                          (previous[diagonal + 1] ?? -1)
              ? diagonal + 1
              : diagonal - 1;
          final px = previous[pk] ?? 0, py = px - pk;
          while (bx > px && by > py) {
            reverse.add(TextEdit(TextEditKind.equal, a[bx - 1], bx, by));
            bx--;
            by--;
          }
          if (depth == 0) break;
          if (bx == px) {
            reverse.add(TextEdit(TextEditKind.add, b[by - 1], null, by));
            by--;
          } else {
            reverse.add(TextEdit(TextEditKind.remove, a[bx - 1], bx, null));
            bx--;
          }
        }
        return TextDiff(reverse.reversed.toList(growable: false));
      }
    }
  }
  throw StateError('No edit path.');
}
