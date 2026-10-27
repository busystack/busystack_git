import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:busystack_git/busystack_git.dart';
import 'package:busystack_git/src/content_identity.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'support/repository_fixture.dart';

void main() {
  test(
    'content identities preserve exact bytes, mode and binary semantics',
    () async {
      for (final size in [0, 7, 65535, 65536, 2 * 1024 * 1024]) {
        for (final (suffix, mode, availability) in [
          (
            [0xef, 0xbb, 0xbf, 13, 10, 122],
            '100644',
            ContentAvailability.present,
          ),
          ([13, 10, 122], '100755', ContentAvailability.present),
          ([13, 10, 122], '120000', ContentAvailability.symlink),
          ([0], '120000', ContentAvailability.binary),
          ([0xff], '100644', ContentAvailability.binary),
        ]) {
          final bytes = Uint8List(size + suffix.length)..fillRange(0, size, 97);
          bytes.setRange(size, bytes.length, suffix);
          final before = Uint8List.fromList(bytes);
          const prefix = 'repository:path:mode:';
          final expected = sha256.convert([
            ...utf8.encode(prefix),
            ...bytes,
          ]).toString();
          final result = await identifyContent(
            bytes,
            mode: mode,
            tokenPrefix: prefix,
          );
          expect(result.token, expected);
          expect(result.availability, availability);
          expect(bytes, before);
          final classified = await identifyContent(bytes, mode: mode);
          expect(classified.availability, availability);
          expect(classified.token, isEmpty);
        }
      }
    },
  );

  test(
    'large content yields to input and observes cancellation on return',
    () async {
      final bytes = Uint8List(4 * 1024 * 1024)
        ..fillRange(0, 4 * 1024 * 1024, 97);
      final cancellation = GitCancellation();
      var yielded = false;
      final work = identifyContent(
        bytes,
        mode: '100644',
        tokenPrefix: 'review:',
        cancellation: cancellation,
      );
      Timer.run(() {
        yielded = true;
        cancellation.cancel();
      });
      await expectLater(
        work,
        throwsA(
          isA<GitException>().having(
            (error) => error.code,
            'code',
            GitErrorCode.cancelled,
          ),
        ),
      );
      expect(yielded, isTrue);
      await expectLater(
        identifyContent(bytes, mode: '100644', cancellation: cancellation),
        throwsA(
          isA<GitException>().having(
            (error) => error.code,
            'code',
            GitErrorCode.cancelled,
          ),
        ),
      );
    },
  );

  test(
    'large repository content keeps index, working bytes and review tokens exact',
    () async {
      final fixture = await RepositoryFixture.create();
      addTearDown(fixture.close);
      final bytes = Uint8List.fromList(
        utf8.encode('\uFEFF${'prose\r\n' * 300000}no final newline'),
      );
      final path = RepoPath.text('large prose.md');
      final head = await fixture.commit(path.utf8Path!, bytes, 'large prose');
      final indexBefore = await File(
        '${fixture.repository.gitDir}/index',
      ).readAsBytes();
      final changed = Uint8List.fromList(bytes)..[bytes.length - 1] = 33;
      await File('${fixture.root.path}/${path.utf8Path}').writeAsBytes(changed);
      for (final (version, expected) in [
        (const ContentVersion.index(), bytes),
        (ContentVersion(ContentKind.commit, revision: head), bytes),
        (const ContentVersion.working(), changed),
      ]) {
        final content = await fixture.engine.content(
          fixture.repository,
          path,
          version,
        );
        expect(content.bytes, expected);
        expect(content.availability, ContentAvailability.present);
        expect(utf8.encode(content.text!), expected);
        expect(
          content.token,
          sha256.convert([
            ...utf8.encode(
              '${fixture.repository.key}:${path.key}:${content.mode}:',
            ),
            ...expected,
          ]).toString(),
        );
      }
      expect(
        await File('${fixture.repository.gitDir}/index').readAsBytes(),
        indexBefore,
      );
      expect(
        await File('${fixture.root.path}/${path.utf8Path}').readAsBytes(),
        changed,
      );
      expect(await fixture.git(['rev-parse', 'HEAD']), head.value);
    },
  );
}
