import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:busystack_git/busystack_git.dart';
import 'package:busystack_git/src/linux_paths.dart';
import 'package:test/test.dart';

import 'support/repository_fixture.dart';
import 'support/isolated_runner.dart';

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

  test(
    'nested repositories remain single parent entries during watching',
    () async {
      await fixture.commit('parent.md', utf8.encode('parent'), 'parent');
      final nested = await Directory('${fixture.root.path}/nested').create();
      await fixture.git(['init', '-b', 'nested'], cwd: nested.path);
      await File('${nested.path}/child.md').writeAsString('child');
      await fixture.git(['add', '.'], cwd: nested.path);
      await fixture.git(['commit', '-m', 'child'], cwd: nested.path);
      final before = await fixture.engine.status(fixture.repository);
      expect(before.changes.single.path.display, 'nested');
      expect(before.changes.single.directory, isTrue);
      final observed = await watch();
      await changed(
        observed.events,
        () =>
            File('${fixture.root.path}/parent.md').writeAsString('parent edit'),
      );
      final after = await fixture.engine.status(fixture.repository);
      expect(after.indexToken, before.indexToken);
      expect(
        after.changes.where(
          (change) => change.path.display.startsWith('nested'),
        ),
        hasLength(1),
      );
      expect(await File('${nested.path}/child.md').readAsString(), 'child');
      expect(
        await fixture.git(['log', '-1', '--format=%s'], cwd: nested.path),
        'child',
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
    await for (final entry in Directory(
      '/proc/$pid/fd',
    ).list(followLinks: false)) {
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
      await for (final entry in Directory(
        '/proc/$pid/fd',
      ).list(followLinks: false)) {
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

  test('closing one watcher preserves another watcher usage lease', () async {
    final first = await watch();
    final second = await watch();
    final descriptor = LinuxPaths.secureOpen(
      utf8.encode('${fixture.repository.gitDir}/busystack-open.lock'),
      create: true,
    );
    try {
      expect(LinuxPaths.tryLock(descriptor), isFalse);
      await first.subscription.cancel();
      expect(LinuxPaths.tryLock(descriptor), isFalse);
      await second.subscription.cancel();
      expect(LinuxPaths.tryLock(descriptor), isTrue);
    } finally {
      LinuxPaths.close(descriptor);
    }
  });

  for (final sample in {
    'traversal': '../escape\u0000',
    'unterminated': 'unterminated',
  }.entries) {
    test(
      'malformed watch output reports an error and releases its lease: ${sample.key}',
      () async {
        final engine = GitEngine(
          runner: _WatchPathRunner(
            IsolatedGitRunner(fixture.home),
            utf8.encode(sample.value),
          ),
        );
        final failure = Completer<GitException>();
        final subscription = engine
            .watch(fixture.repository)
            .listen(
              (_) => fail(
                'Malformed output cannot become a successful invalidation.',
              ),
              onError: (Object error) {
                expect(error, isA<GitException>());
                if (!failure.isCompleted)
                  failure.complete(error as GitException);
              },
            );
        addTearDown(subscription.cancel);
        expect(
          (await failure.future.timeout(const Duration(seconds: 3))).code,
          GitErrorCode.invalidRequest,
        );
        // fork() briefly inherits close-on-exec descriptors before exec.
        // A duplicate makes that lifetime deterministic without forking the
        // multithreaded Dart VM or relying on another test's process timing.
        final lockPath = '${fixture.repository.gitDir}/busystack-open.lock';
        final owned = <int>[];
        await for (final entry in Directory(
          '/proc/$pid/fd',
        ).list(followLinks: false)) {
          if (entry is! Link) continue;
          try {
            if (await entry.target() == lockPath) {
              owned.add(int.parse(entry.uri.pathSegments.last));
            }
          } on FileSystemException catch (error) {
            if (error.osError?.errorCode != 2) rethrow;
          }
        }
        expect(owned, hasLength(1));
        final duplicate = DynamicLibrary.process()
            .lookupFunction<Int32 Function(Int32), int Function(int)>(
              'dup',
            )(owned.single);
        expect(duplicate, isNonNegative);
        final descriptor = LinuxPaths.secureOpen(
          utf8.encode(lockPath),
          create: true,
        );
        try {
          expect(LinuxPaths.tryLock(descriptor), isFalse);
          await subscription.cancel();
          final available = LinuxPaths.tryLock(descriptor);
          final retained = <String>[];
          if (!available) {
            await for (final entry in Directory(
              '/proc/$pid/fd',
            ).list(followLinks: false)) {
              if (entry is! Link) continue;
              try {
                final target = await entry.target();
                if (target.startsWith(fixture.directory.path)) {
                  retained.add('${entry.path}: $target');
                }
              } on FileSystemException catch (error) {
                if (error.osError?.errorCode != 2) rethrow;
              }
            }
          }
          expect(available, isTrue, reason: 'Retained descriptors: $retained');
        } finally {
          LinuxPaths.close(descriptor);
          LinuxPaths.close(duplicate);
        }
      },
    );
  }
}

final class _WatchPathRunner implements GitRunner {
  _WatchPathRunner(this.inner, this.output);
  final GitRunner inner;
  final List<int> output;
  @override
  Future<GitRunResult> run(
    List<String> arguments, {
    required String cwd,
    List<int>? input,
    GitCancellation? cancellation,
    Duration? deadline,
    void Function(List<int>)? onStdout,
    void Function(String)? onProgress,
    String Function(String)? redactDiagnostic,
    Map<String, String> environment = const {},
    Map<int, List<int>> byteArguments = const {},
    int? maximumBytes,
  }) => arguments.contains('ls-files')
      ? Future.value(GitRunResult(0, Uint8List.fromList(output), Uint8List(0)))
      : inner.run(
          arguments,
          cwd: cwd,
          input: input,
          cancellation: cancellation,
          deadline: deadline,
          onStdout: onStdout,
          onProgress: onProgress,
          redactDiagnostic: redactDiagnostic,
          environment: environment,
          byteArguments: byteArguments,
          maximumBytes: maximumBytes,
        );
}
