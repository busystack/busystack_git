import 'dart:convert';
import 'dart:io';

import 'package:busystack_git/busystack_git.dart';
import 'package:test/test.dart';

import 'support/isolated_runner.dart';
import 'support/repository_fixture.dart';

void main() {
  late RepositoryFixture fixture;
  setUp(() async {
    fixture = await RepositoryFixture.create();
    await fixture.commit('base.md', utf8.encode('base\n'), 'Base');
  });
  tearDown(() => fixture.close());

  test(
    'a status read reconciles one external index write without accepting an old mutation review',
    () async {
      final reviewed = await fixture.engine.status(fixture.repository);
      var reads = 0;
      final engine = GitEngine(
        authorize: (_) => true,
        runner: IsolatedGitRunner(
          fixture.home,
          beforeRun: (arguments, _) async {
            if (arguments.contains('--porcelain=v2') && ++reads == 1) {
              await File(
                '${fixture.root.path}/external.md',
              ).writeAsString('external staged bytes\n');
              await fixture.git(['add', '--', 'external.md']);
            }
          },
        ),
      );
      final current = await engine.status(fixture.repository);
      expect(reads, 2);
      expect(current.indexToken, isNot(reviewed.indexToken));
      expect(current.changes.single.path.display, 'external.md');
      expect(current.changes.single.staged, isTrue);
      final refused = await engine.mutate(
        fixture.repository,
        CommitIndex(
          'Old review must stay invalid',
          expectedHead: reviewed.head,
          expectedIndex: reviewed.indexToken,
        ),
      );
      expect(refused.error?.code, GitErrorCode.staleReview);
      expect(await fixture.git(['rev-list', '--count', 'HEAD']), '1');
      expect(
        await fixture.git(['show', ':external.md']),
        'external staged bytes',
      );
    },
  );

  test(
    'continuously changing status fails after a bounded number of read attempts',
    () async {
      var reads = 0;
      final engine = GitEngine(
        runner: IsolatedGitRunner(
          fixture.home,
          beforeRun: (arguments, _) async {
            if (arguments.contains('--porcelain=v2')) {
              await File(
                '${fixture.root.path}/external.md',
              ).writeAsString('external ${++reads}\n');
              await fixture.git(['add', '--', 'external.md']);
            }
          },
        ),
      );
      await expectLater(
        engine.status(fixture.repository),
        throwsA(
          isA<GitException>().having(
            (error) => error.code,
            'code',
            GitErrorCode.staleReview,
          ),
        ),
      );
      expect(reads, 3);
      expect(await fixture.git(['show', ':external.md']), 'external 3');
    },
  );

  test(
    'successful pull is reconciled after an external index write and is never repeated',
    () async {
      final remote = '${fixture.directory.path}/remote.git';
      await fixture.git(['init', '--bare', remote]);
      await fixture.git(['remote', 'add', 'team', remote]);
      await fixture.git(['push', '-u', 'team', 'main']);
      final writer = '${fixture.directory.path}/writer';
      await fixture.git(['clone', '--branch', 'main', remote, writer]);
      await File('$writer/remote.md').writeAsString('remote bytes\n');
      await fixture.git(['add', '.'], cwd: writer);
      await fixture.git(['commit', '-m', 'Remote'], cwd: writer);
      await fixture.git(['push', 'origin', 'main'], cwd: writer);
      final target = await fixture.git(['rev-parse', 'HEAD'], cwd: writer);
      final reviewed = await fixture.engine.status(fixture.repository);
      var pulls = 0, afterPullReads = 0;
      final engine = GitEngine(
        authorize: (_) => true,
        runner: IsolatedGitRunner(
          fixture.home,
          beforeRun: (arguments, _) async {
            if (arguments.contains('pull')) pulls++;
            if (pulls != 0 &&
                arguments.contains('--porcelain=v2') &&
                ++afterPullReads == 1) {
              await File(
                '${fixture.root.path}/external.md',
              ).writeAsString('keep staged\n');
              await fixture.git(['add', '--', 'external.md']);
            }
          },
        ),
      );
      final result = await engine.mutate(
        fixture.repository,
        PullRemote(
          'team',
          'main',
          PullStrategy.fastForwardOnly,
          expectedHead: reviewed.head,
          expectedIndex: reviewed.indexToken,
        ),
      );
      expect(result.completed, isTrue, reason: '${result.error}');
      expect(pulls, 1);
      expect(afterPullReads, 2);
      expect(result.snapshot!.head!.value, target);
      expect(result.snapshot!.changes.single.staged, isTrue);
      expect(await fixture.git(['show', ':external.md']), 'keep staged');
      expect(
        await File('${fixture.root.path}/remote.md').readAsBytes(),
        utf8.encode('remote bytes\n'),
      );
      expect(await fixture.git(['rev-list', '--count', 'HEAD']), '2');
    },
  );

  test(
    'a successful mutation with continuously changing reconciliation remains uncertain',
    () async {
      final reviewed = await fixture.engine.status(fixture.repository);
      var created = false, reads = 0, branchCommands = 0;
      final engine = GitEngine(
        authorize: (_) => true,
        runner: IsolatedGitRunner(
          fixture.home,
          beforeRun: (arguments, _) async {
            if (arguments.contains('branch') &&
                arguments.contains('created-once')) {
              created = true;
              branchCommands++;
            }
            if (created && arguments.contains('--porcelain=v2')) {
              await File(
                '${fixture.root.path}/external.md',
              ).writeAsString('external ${++reads}\n');
              await fixture.git(['add', '--', 'external.md']);
            }
          },
        ),
      );
      final result = await engine.mutate(
        fixture.repository,
        BranchMutation(
          BranchAction.create,
          'created-once',
          start: reviewed.head,
          expectedHead: reviewed.head,
          expectedIndex: reviewed.indexToken,
        ),
      );
      expect(
        result.phase,
        GitOperationPhase.uncertain,
        reason: '${result.error}',
      );
      expect(result.error?.code, GitErrorCode.uncertainOutcome);
      expect(branchCommands, 1);
      expect(reads, 3);
      expect(
        await fixture.git(['rev-parse', 'refs/heads/created-once']),
        reviewed.head!.value,
      );
      expect(await fixture.git(['show', ':external.md']), 'external 3');
      expect(await fixture.git(['rev-list', '--count', 'HEAD']), '1');
    },
  );
}
