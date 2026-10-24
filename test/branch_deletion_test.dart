import 'dart:convert';
import 'dart:io';
import 'package:busystack_git/busystack_git.dart';
import 'package:test/test.dart';
import 'support/repository_fixture.dart';

void main() {
  late RepositoryFixture f;
  late GitOid original;
  setUp(() async {
    f = await RepositoryFixture.create();
    original = await f.commit('a', utf8.encode('original\n'), 'original');
    await f.git(['branch', 'reviewed']);
  });
  tearDown(() => f.close());

  for (final force in [false, true]) {
    test(
      'a real preparing hook advancing a branch invalidates deletion (force=$force)',
      () async {
        final advanced = await f.commit(
          'a',
          utf8.encode('advanced\n'),
          'advanced',
        );
        final index = await File('${f.repository.gitDir}/index').readAsBytes();
        final hook = File('${f.directory.path}/advance-once');
        final marker = '${f.directory.path}/advanced';
        final events = File('${f.directory.path}/events');
        // This is Git's real pre-lock phase, after the engine's preflight. The
        // isolated fixture's terminal Git does not inherit the outer hooks.
        await hook.writeAsString('''#!/bin/sh
printf '%s\\n' "\$1" >> '${events.path}'
if [ "\$1" = preparing ] && [ ! -e '$marker' ]; then
  : > '$marker'
  /usr/bin/git update-ref refs/heads/reviewed ${advanced.value} || exit 1
fi
cat > /dev/null
''');
        await Process.run('/bin/chmod', ['0700', hook.path]);
        await f.git([
          'config',
          'hook.fixture-advance.event',
          'reference-transaction',
        ]);
        await f.git(['config', 'hook.fixture-advance.command', hook.path]);
        final result = await f.mutate(
          (state) => BranchMutation(
            BranchAction.delete,
            'reviewed',
            expectedTip: original,
            forceDeleteReviewed: force,
            expectedHead: state.head,
            expectedIndex: state.indexToken,
          ),
        );
        expect(
          result.error?.code,
          GitErrorCode.staleReview,
          reason: '${result.error}',
        );
        expect(await events.readAsString(), contains('prepared\n'));
        expect(
          await f.git(['rev-parse', 'refs/heads/reviewed']),
          advanced.value,
        );
        expect(await f.git(['rev-parse', 'HEAD']), advanced.value);
        expect(await File('${f.repository.gitDir}/index').readAsBytes(), index);
        expect(await File('${f.root.path}/a').readAsString(), 'advanced\n');
      },
    );
  }

  test(
    'reviewed deletion retains native branch cleanup and configured hooks',
    () async {
      final events = '${f.directory.path}/events';
      await f.git(['config', 'branch.reviewed.description', 'Reviewed branch']);
      await f.git([
        'config',
        'hook.fixture-notify.event',
        'reference-transaction',
      ]);
      await f.git([
        'config',
        'hook.fixture-notify.command',
        'printf "%s\\n" "\$1" >> "$events"; cat > /dev/null #',
      ]);
      final result = await f.mutate(
        (state) => BranchMutation(
          BranchAction.delete,
          'reviewed',
          expectedTip: original,
          expectedHead: state.head,
          expectedIndex: state.indexToken,
        ),
      );
      expect(result.completed, isTrue, reason: '${result.error}');
      expect(
        (await f.run(['show-ref', '--verify', 'refs/heads/reviewed'])).exitCode,
        isNot(0),
      );
      expect(
        (await f.run([
          'config',
          '--get',
          'branch.reviewed.description',
        ])).exitCode,
        1,
      );
      expect(await File(events).readAsString(), contains('committed\n'));
    },
  );

  test(
    'disabled transaction hooks stop for review without overriding configuration',
    () async {
      await f.git(['config', 'hook.reference-transaction.enabled', 'false']);
      final result = await f.mutate(
        (state) => BranchMutation(
          BranchAction.delete,
          'reviewed',
          expectedTip: original,
          expectedHead: state.head,
          expectedIndex: state.indexToken,
        ),
      );
      expect(result.error?.code, GitErrorCode.invalidRequest);
      expect(result.error?.diagnostic, contains('reference-transaction'));
      expect(await f.git(['rev-parse', 'refs/heads/reviewed']), original.value);
      expect(
        await f.git(['config', '--get', 'hook.reference-transaction.enabled']),
        'false',
      );
    },
  );

  test('native unmerged deletion refuses without a force fallback', () async {
    final unmerged = GitOid(
      await f.git([
        'commit-tree',
        await f.git(['rev-parse', 'HEAD^{tree}']),
        '-p',
        original.value,
        '-m',
        'unmerged branch commit',
      ]),
    );
    await f.git(['update-ref', 'refs/heads/reviewed', unmerged.value]);
    final result = await f.mutate(
      (state) => BranchMutation(
        BranchAction.delete,
        'reviewed',
        expectedTip: unmerged,
        expectedHead: state.head,
        expectedIndex: state.indexToken,
      ),
    );
    expect(result.completed, isFalse);
    expect(await f.git(['rev-parse', 'refs/heads/reviewed']), unmerged.value);
    expect(await f.git(['rev-parse', 'HEAD']), original.value);
  });
}
