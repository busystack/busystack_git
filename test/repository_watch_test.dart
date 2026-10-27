import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:busystack_git/busystack_git.dart';
import 'package:busystack_git/src/linux_paths.dart';
import 'package:test/test.dart';

import 'support/repository_fixture.dart';

void main() {
  late RepositoryFixture fixture;
  setUp(() async => fixture = await RepositoryFixture.create());
  tearDown(() async => fixture.close());

  Future<({StreamSubscription<void> subscription, List<DateTime> events})>
  watch() async {
    final ready = Completer<void>(), events = <DateTime>[];
    final subscription = fixture.engine.watch(fixture.repository).listen((_) {
      events.add(DateTime.now());
      if (!ready.isCompleted) ready.complete();
    });
    addTearDown(subscription.cancel);
    await ready.future.timeout(const Duration(seconds: 8));
    events.clear();
    return (subscription: subscription, events: events);
  }

  Future<void> changed(
    List<DateTime> events,
    Future<void> Function() change,
  ) async {
    events.clear();
    await change();
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (events.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(
      events,
      isNotEmpty,
      reason: 'Nested changes need an event, not a poll.',
    );
  }

  test(
    'idle watches avoid scans but nested tracked edits refresh promptly',
    () async {
      await fixture.commit(
        'chapters/part/notes.md',
        utf8.encode('first\n'),
        'base',
      );
      final index = (await fixture.engine.status(
        fixture.repository,
      )).indexToken;
      final observed = await watch();
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(
        observed.events,
        isEmpty,
        reason: 'An unchanged repository needs no five-second full scan.',
      );
      await changed(
        observed.events,
        () => File(
          '${fixture.root.path}/chapters/part/notes.md',
        ).writeAsString('later\n'),
      );
      final status = await fixture.engine.status(fixture.repository);
      expect(status.indexToken, index);
      expect(status.changes.single.path.display, 'chapters/part/notes.md');
      expect(status.changes.single.unstaged, isTrue);
    },
  );

  test(
    'untracked and byte-named parents receive real directory events',
    () async {
      final rawParent = [...utf8.encode('${fixture.root.path}/'), 255];
      LinuxPaths.close(
        LinuxPaths.secureOpen(
          rawParent,
          directory: true,
          createDirectories: true,
        ),
      );
      final rawPath = [...rawParent, 47, ...utf8.encode('notes.md')];
      final rawFile = File.fromRawPath(Uint8List.fromList(rawPath));
      await rawFile.writeAsBytes([1]);
      await fixture.git(['add', '.']);
      await fixture.git(['commit', '-m', 'byte parent']);
      final untracked = File('${fixture.root.path}/untracked/deep/draft.md');
      await untracked.parent.create(recursive: true);
      await untracked.writeAsString('draft');
      final observed = await watch();
      await changed(observed.events, () => rawFile.writeAsBytes([2]));
      await changed(
        observed.events,
        () => untracked.writeAsString('edited draft'),
      );
      final status = await fixture.engine.status(fixture.repository);
      final byteChange = status.changes.singleWhere(
        (change) => change.unstaged,
      );
      expect(byteChange.path, RepoPath([255, 47, ...utf8.encode('notes.md')]));
      expect(
        status.changes.where((change) => change.untracked).single.path.display,
        'untracked/deep/draft.md',
      );
    },
  );

  test(
    'nested reference replacement invalidates without inspecting loose refs',
    () async {
      final first = await fixture.commit('a', [1], 'first');
      final second = await fixture.commit('a', [2], 'second');
      await fixture.git(['branch', 'topic/nested', first.value]);
      final observed = await watch();
      await changed(observed.events, () async {
        await fixture.git([
          'update-ref',
          'refs/heads/topic/nested',
          second.value,
          first.value,
        ]);
      });
      final references = await fixture.engine.references(fixture.repository);
      expect(
        references
            .singleWhere((ref) => ref.name == 'refs/heads/topic/nested')
            .oid,
        second,
      );
    },
  );

  test('directory bounds retain full status and five-second fallback', () async {
    for (var index = 0; index < 280; index++) {
      final file = File(
        '${fixture.root.path}/tracked/dir-${index.toString().padLeft(5, '0')}/notes.md',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString('base');
    }
    await fixture.git(['add', '.']);
    await fixture.git(['commit', '-m', 'bounded watch fixture']);
    final observed = await watch();
    var descriptors = 0;
    await for (final entry in Directory('/proc/$pid/fd').list()) {
      if (entry is! Link) continue;
      try {
        if ((await entry.target()).startsWith('${fixture.directory.path}/'))
          descriptors++;
      } on FileSystemException catch (error) {
        if (error.osError?.errorCode != 2) rethrow;
      }
    }
    expect(descriptors, lessThanOrEqualTo(257));
    observed.events.clear();
    await File(
      '${fixture.root.path}/tracked/dir-00279/notes.md',
    ).writeAsString('changed');
    final deadline = DateTime.now().add(const Duration(seconds: 7));
    while (observed.events.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(observed.events, isNotEmpty);
    final status = await fixture.engine.status(fixture.repository);
    expect(status.changes.single.path.display, 'tracked/dir-00279/notes.md');
  });

  test(
    'watches reject symlink descendants and release all owned descriptors',
    () async {
      final outside = await Directory(
        '${fixture.directory.path}/outside',
      ).create();
      final outsideFile = File('${outside.path}/private');
      await outsideFile.writeAsString('retained');
      await Link('${fixture.root.path}/link').create(outside.path);
      await fixture.git(['add', '.']);
      await fixture.git(['commit', '-m', 'link']);
      final observed = await watch();
      await outsideFile.writeAsString('external edit');
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(observed.events, isEmpty);
      await observed.subscription.cancel();
      final retained = <String>[];
      await for (final entry in Directory('/proc/$pid/fd').list()) {
        if (entry is! Link) continue;
        try {
          final target = await entry.target();
          if (target.startsWith('${fixture.directory.path}/'))
            retained.add(target);
        } on FileSystemException catch (error) {
          if (error.osError?.errorCode != 2) rethrow;
        }
      }
      expect(
        retained,
        isEmpty,
        reason:
            'No directory or usage-lock descriptor may survive cancellation.',
      );
    },
  );
}
