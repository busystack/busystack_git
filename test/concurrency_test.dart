import 'dart:convert';
import 'dart:io';
import 'package:busystack_git/busystack_git.dart';
import 'package:test/test.dart';
import 'support/repository_fixture.dart';

void main() {
  late RepositoryFixture f;
  setUp(() async {
    f = await RepositoryFixture.create();
    await f.commit('a', utf8.encode('base'), 'base');
  });
  tearDown(() async => f.close());
  Future<Process> hold(String path) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      'run',
      'test/support/hold_repository_lock.dart',
      path,
      f.home,
    ]);
    process.stderr.drain<void>();
    expect(
      await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 15)),
      'locked',
    );
    return process;
  }

  test(
    'BusyStack applications coordinate common worktrees across processes and recover from a crash',
    () async {
      await f.git([
        'worktree',
        'add',
        '-b',
        'linked',
        '${f.directory.path}/linked',
      ]);
      final child = await hold('${f.directory.path}/linked');
      try {
        final outcome = await f.mutate(
          (s) => BranchMutation(
            BranchAction.create,
            'blocked',
            start: s.head,
            expectedHead: s.head,
            expectedIndex: s.indexToken,
          ),
        );
        expect(outcome.error!.code, GitErrorCode.locked);
        expect(
          (await f.run([
            'show-ref',
            '--verify',
            'refs/heads/blocked',
          ])).exitCode,
          isNot(0),
        );
      } finally {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
      }
      final after = await f.mutate(
        (s) => BranchMutation(
          BranchAction.create,
          'after-crash',
          start: s.head,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(after.completed, isTrue, reason: '${after.error}');
      expect(
        await f.git(['rev-parse', 'refs/heads/after-crash']),
        (await f.engine.status(f.repository)).head!.value,
      );
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
  test(
    'parent submodule updates and child mutations coordinate across processes',
    () async {
      final source = await Directory('${f.directory.path}/source').create();
      await f.git(['init', '-b', 'main'], cwd: source.path);
      await File('${source.path}/a').writeAsString('child');
      await f.git(['add', '.'], cwd: source.path);
      await f.git(['commit', '-m', 'child'], cwd: source.path);
      await f.git([
        '-c',
        'protocol.file.allow=always',
        'submodule',
        'add',
        source.path,
        'nested',
      ]);
      await f.git(['commit', '-m', 'submodule']);
      final nested = (await f.engine.discover('${f.root.path}/nested'))!;
      final heldParent = await hold(f.root.path);
      try {
        final state = await f.engine.status(nested);
        final outcome = await f.engine.mutate(
          nested,
          BranchMutation(
            BranchAction.create,
            'blocked-child',
            start: state.head,
            expectedHead: state.head,
            expectedIndex: state.indexToken,
          ),
        );
        expect(outcome.error!.code, GitErrorCode.locked);
        expect(
          (await f.run([
            'show-ref',
            '--verify',
            'refs/heads/blocked-child',
          ], cwd: nested.root)).exitCode,
          isNot(0),
        );
      } finally {
        heldParent.kill(ProcessSignal.sigkill);
        await heldParent.exitCode;
      }
      final heldChild = await hold(nested.root);
      try {
        final path = RepoPath.text('nested');
        final content = await f.engine.content(
          f.repository,
          path,
          const ContentVersion.working(),
        );
        final outcome = await f.mutate(
          (state) => SubmoduleMutation(
            SubmoduleAction.synchronize,
            [path],
            expectedHead: state.head,
            expectedIndex: state.indexToken,
            contentTokens: {path.key: content.token},
          ),
        );
        expect(outcome.error!.code, GitErrorCode.locked);
      } finally {
        heldChild.kill(ProcessSignal.sigkill);
        await heldChild.exitCode;
      }
      expect(await File('${nested.root}/a').readAsString(), 'child');
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
  test(
    'a terminal index write invalidates a waiting review and is never overwritten',
    () async {
      final before = await f.engine.status(f.repository),
          child = await hold(f.root.path);
      try {
        await File('${f.root.path}/a').writeAsString('terminal staged');
        final pending = f.engine.mutate(
          f.repository,
          StagePaths(
            [RepoPath.text('a')],
            expectedHead: before.head,
            expectedIndex: before.indexToken,
          ),
        );
        await f.git(['add', '--', 'a']);
        child.stdin.writeln('release');
        await child.stdin.close();
        await child.exitCode;
        final outcome = await pending;
        expect(outcome.error!.code, GitErrorCode.staleReview);
        expect(await f.git(['show', ':a']), 'terminal staged');
        expect(await File('${f.root.path}/.git/index.lock').exists(), isFalse);
      } finally {
        if (child.kill(ProcessSignal.sigkill)) await child.exitCode;
      }
    },
  );
  test(
    'an external file write during a real clean filter prevents transactional index installation',
    () async {
      await f.commit(
        '.gitattributes',
        utf8.encode('a filter=fixture\n'),
        'attributes',
      );
      await f.commit('other', utf8.encode('base other'), 'other');
      await File(
        '${f.root.path}/other',
      ).writeAsString('unrelated staged bytes');
      await f.git(['add', 'other']);
      await File('${f.root.path}/a').writeAsString('reviewed bytes');
      final marker = File('${f.directory.path}/filter-entered'),
          release = File('${f.directory.path}/filter-release');
      final filter = File('${f.directory.path}/clean.sh');
      await filter.writeAsString(
        '#!/bin/sh\ncase "\$GIT_INDEX_FILE" in\n*busystack-index-*) '
        'touch "${marker.path}"; while [ ! -f "${release.path}" ]; do sleep 0.01; done;;\nesac\ncat\n',
      );
      await Process.run('chmod', ['0700', filter.path]);
      await f.git(['config', 'filter.fixture.clean', filter.path]);
      final reviewed = await f.engine.status(
        f.repository,
        policy: GitReadPolicy.authorized,
      );
      final a = await f.git(['rev-parse', ':a']),
          other = await f.git(['rev-parse', ':other']);
      final pending = f.engine.mutate(
        f.repository,
        StagePaths(
          [RepoPath.text('a')],
          expectedHead: reviewed.head,
          expectedIndex: reviewed.indexToken,
          expectedSnapshot: reviewed.token,
        ),
      );
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (!await marker.exists() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(await marker.exists(), isTrue);
        await File(
          '${f.root.path}/a',
        ).writeAsString('concurrent external bytes');
      } finally {
        await release.writeAsString('release');
      }
      final outcome = await pending;
      expect(outcome.error!.code, GitErrorCode.staleReview);
      expect(await f.git(['rev-parse', ':a']), a);
      expect(await f.git(['rev-parse', ':other']), other);
      expect(
        await File('${f.root.path}/a').readAsString(),
        'concurrent external bytes',
      );
      expect(await File('${f.repository.gitDir}/index.lock').exists(), isFalse);
    },
  );
}
