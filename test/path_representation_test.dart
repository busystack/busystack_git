import 'dart:convert';
import 'dart:typed_data';

import 'package:busystack_git/busystack_git.dart';
import 'package:test/test.dart';

void main() {
  test(
    'path display, serialization and sorting retain immutable byte identity',
    () {
      final cases = [
        (utf8.encode('\uFEFFdir/notes\t\n.md'), r'\uFEFFdir/notes\t\n.md'),
        (utf8.encode(r'dir/back\slash.md'), r'dir/back\\slash.md'),
        (utf8.encode('café/:(glob)*'), 'café/:(glob)*'),
        ([100, 105, 114, 47, 0xff, 0x61], r'dir/\xffa'),
        (utf8.encode('-leading dash'), '-leading dash'),
      ];
      final paths = <RepoPath>[];
      for (final (raw, display) in cases) {
        final input = Uint8List.fromList(raw), original = List<int>.of(raw);
        final path = RepoPath(input);
        // Initialize every derived representation before attempting to alter the
        // original input, then read them in another order and deserialize.
        expect(path.display, display);
        expect(path.basename, display.split('/').last);
        expect(
          path.parent,
          display.contains('/')
              ? display.substring(0, display.lastIndexOf('/'))
              : '',
        );
        expect(base64Decode(path.key), original);
        final text = path.utf8Path;
        input.fillRange(0, input.length, 120);
        expect(() => path.bytes[0] = 120, throwsUnsupportedError);
        expect(path.bytes, original);
        expect(path.utf8Path, text);
        if (text != null) expect(utf8.encode(text), original);
        expect(path.key, base64Encode(original));
        expect(path.display, display);
        final restored = RepoPath.fromJson(path.toJson());
        expect(restored, path);
        expect(restored.hashCode, path.hashCode);
        expect(restored.display, display);
        expect(restored.utf8Path, text);
        paths.add(path);
      }
      final expected = cases.map((c) => c.$2).toList()..sort();
      paths.sort();
      expect(paths.map((path) => path.display), expected);
      expect(
        paths.singleWhere((p) => p.display == r'dir/\xffa').utf8Path,
        isNull,
      );
      expect({for (final p in paths) p: p.toJson()}, hasLength(cases.length));
    },
  );
}
