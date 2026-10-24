import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:busystack_git/busystack_git.dart';
import 'package:test/test.dart';
import 'support/isolated_runner.dart';

void main() {
  late Directory fixture, root;
  late GitEngine engine;
  late RepositoryId repo;
  late Directory helperBuild;
  late String helper;
  setUpAll(() async {
    helperBuild = await Directory.systemTemp.createTemp('bsg-helper-test-');
    helper = '${helperBuild.path}/busystack-git-helper';
    final result = await Process.run('cc', [
      '-std=c11',
      '-O2',
      '-Wall',
      '-Wextra',
      '-Werror',
      'native/git_helper.c',
      '-o',
      helper,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
  tearDownAll(() async => helperBuild.delete(recursive: true));
  Future<String> git(List<String> args, {String? cwd}) async {
    final result = await Process.run(
      '/usr/bin/git',
      args,
      workingDirectory: cwd ?? root.path,
      environment: {
        'HOME': '${fixture.path}/home',
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_AUTHOR_NAME': 'Fixture',
        'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
        'GIT_COMMITTER_NAME': 'Fixture',
        'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
      },
    );
    if (result.exitCode != 0) fail('${args.join(' ')}: ${result.stderr}');
    return (result.stdout as String).trimRight();
  }

  Future<GitOid> commit(String name, String value, String message) async {
    await File('${root.path}/$name').writeAsString(value);
    await git(['add', '--', name]);
    await git(['commit', '-m', message]);
    return GitOid(await git(['rev-parse', 'HEAD']));
  }

  Future<GitOutcome> mutate(GitMutation Function(GitSnapshot) build) async {
    final state = await engine.status(repo);
    return engine.mutate(repo, build(state));
  }

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('bsg-workflows-');
    root = await Directory('${fixture.path}/repo').create();
    await Directory('${fixture.path}/home').create();
    await IsolatedGitRunner.prepare('${fixture.path}/home');
    await git(['init', '-b', 'main']);
    await git(['config', 'user.name', 'Fixture']);
    await git(['config', 'user.email', 'fixture@example.invalid']);
    await commit('a', 'base\n', 'base');
    engine = GitEngine(
      runner: IsolatedGitRunner('${fixture.path}/home'),
      authorize: (_) => true,
      helperPath: helper,
      prompts: (prompt, cancel) async =>
          Uint8List.fromList(utf8.encode('Reviewed message\n')),
    );
    repo = (await engine.discover(root.path))!;
  });
  tearDown(() async => fixture.delete(recursive: true));
  test(
    'merge conflict saves a manual draft, reopens, stages and continues through Git',
    () async {
      await git(['switch', '-c', 'feature']);
      final incoming = await commit('a', 'incoming\n', 'incoming');
      await git(['switch', 'main']);
      await commit('a', 'current\n', 'current');
      final merged = await mutate(
        (s) => MergeRevision(
          incoming,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(merged.phase, GitOperationPhase.stopped);
      expect(merged.snapshot!.operation.kind, GitOperationKind.merge);
      expect(
        merged.snapshot!.operation.actions,
        isNot(contains(GitContinuation.skip)),
      );
      final path = RepoPath.text('a');
      Future<GitOutcome> resolve(bool staged, String text) async {
        final info = await engine.inspect(
          repo,
          GitInspection(GitInspectionKind.conflict, path: path),
        );
        final stages = info['stages'] as Json;
        return mutate(
          (s) => ResolveConflict(
            path,
            ConflictChoice.edited,
            expectedHead: s.head,
            expectedIndex: s.indexToken,
            expectedWorking: (info['working'] as Json)['token'] as String,
            expectedStages: {
              for (final e in stages.entries)
                int.parse(e.key):
                    '${(e.value as Json)['mode']}:${(e.value as Json)['oid']}',
            },
            bytes: Uint8List.fromList(utf8.encode(text)),
            stageResult: staged,
          ),
        );
      }

      expect(
        (await resolve(false, 'manual draft\n')).completed,
        isFalse,
      ); // still an unmerged operation
      final reopened = GitEngine(
        runner: IsolatedGitRunner('${fixture.path}/home'),
        authorize: (_) => true,
      );
      expect(
        (await reopened.content(
          repo,
          path,
          const ContentVersion.working(),
        )).text,
        'manual draft\n',
      );
      expect((await engine.status(repo)).operation.unmerged, isTrue);
      await resolve(true, 'reviewed resolution\n');
      expect((await engine.status(repo)).operation.unmerged, isFalse);
      final done = await mutate(
        (s) => ContinueGitOperation(
          GitOperationKind.merge,
          GitContinuation.continueOperation,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(done.completed, isTrue, reason: '${done.error}');
      expect(
        (await git([
          'rev-list',
          '--parents',
          '-n',
          '1',
          'HEAD',
        ])).split(' ').length,
        3,
      );
      expect(await git(['show', 'HEAD:a']), 'reviewed resolution');
    },
  );
  test('ordered cherry-pick and revert create real commits', () async {
    await git(['switch', '-c', 'topic']);
    final a = await commit('b', 'one\n', 'one');
    final b = await commit('c', 'two\n', 'two');
    await git(['switch', 'main']);
    final picked = await mutate(
      (s) => PickCommits(
        [a, b],
        expectedHead: s.head,
        expectedIndex: s.indexToken,
      ),
    );
    expect(picked.completed, isTrue, reason: '${picked.error}');
    expect(
      (await engine.history(
        repo,
        filter: const HistoryFilter(reference: 'HEAD'),
      )).commits.take(2).map((e) => e.subject),
      ['two', 'one'],
    );
    final reversed = await mutate(
      (s) => PickCommits(
        [s.head!],
        revert: true,
        expectedHead: s.head,
        expectedIndex: s.indexToken,
      ),
    );
    expect(reversed.completed, isTrue);
    expect(await File('${root.path}/c').exists(), isFalse);
    expect(await File('${root.path}/b').exists(), isTrue);
  });
  test(
    'interactive rebase captures Git plan, reorders, rewords, fixups, drops, and resumes edit',
    () async {
      final boundary = (await engine.status(repo)).head!;
      final a = await commit('b', 'one', 'one'),
          b = await commit('c', 'two', 'two');
      final c = await commit('d', 'three', 'three'),
          d = await commit('e', 'four', 'four');
      final e = await commit('f', 'five', 'five');
      final before = await engine.status(repo);
      final plan = await engine.inspect(
        repo,
        GitInspection(GitInspectionKind.rebasePlan, revision: boundary),
      );
      expect((await engine.status(repo)).head, before.head);
      final result = await mutate(
        (s) => RebaseCommits(
          expectedHead: s.head,
          expectedIndex: s.indexToken,
          boundary: boundary,
          interactive: true,
          planToken: plan['token'] as String,
          steps: [
            RebaseStep(RebaseAction.reword, b),
            RebaseStep(RebaseAction.fixup, a),
            RebaseStep(RebaseAction.drop, c),
            RebaseStep(RebaseAction.squash, d),
            RebaseStep(RebaseAction.edit, e),
          ],
        ),
      );
      expect(
        result.phase,
        GitOperationPhase.stopped,
        reason: '${result.error}',
      );
      expect(result.snapshot!.operation.kind, GitOperationKind.rebase);
      expect(await File('${root.path}/d').exists(), isFalse);
      final reopened = GitEngine(
        runner: IsolatedGitRunner('${fixture.path}/home'),
        authorize: (_) => true,
        helperPath: helper,
        prompts: (prompt, cancel) async =>
            Uint8List.fromList(utf8.encode('continued')),
      );
      final state = await reopened.status(repo);
      final done = await reopened.mutate(
        repo,
        ContinueGitOperation(
          GitOperationKind.rebase,
          GitContinuation.continueOperation,
          expectedHead: state.head,
          expectedIndex: state.indexToken,
        ),
      );
      expect(done.completed, isTrue, reason: '${done.error}');
      final history = await reopened.history(
        repo,
        filter: const HistoryFilter(reference: 'HEAD'),
      );
      expect(history.commits.length, 3);
      expect(history.commits[1].subject, 'Reviewed message');
    },
  );
  test(
    'stash identity survives another stash; apply conflict retains stash',
    () async {
      await File('${root.path}/a').writeAsString('first\n');
      expect(
        (await mutate(
          (s) => StashMutation(
            StashAction.create,
            message: 'first',
            expectedHead: s.head,
            expectedIndex: s.indexToken,
          ),
        )).completed,
        isTrue,
      );
      final first = GitOid(
        ((await engine.inspect(
                      repo,
                      const GitInspection(GitInspectionKind.stashes),
                    ))['entries']
                    as List)
                .first['identity']
            as String,
      );
      await File('${root.path}/a').writeAsString('second\n');
      await mutate(
        (s) => StashMutation(
          StashAction.create,
          message: 'second',
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      await commit('a', 'third\n', 'third');
      final popped = await mutate(
        (s) => StashMutation(
          StashAction.pop,
          identity: first,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(popped.phase, GitOperationPhase.stopped);
      expect(
        ((await engine.inspect(
                  repo,
                  const GitInspection(GitInspectionKind.stashes),
                ))['entries']
                as List)
            .length,
        2,
      );
      expect((await engine.status(repo)).operation.actions, isEmpty);
    },
  );
  test(
    'root rebase includes the root and rejects an initial fixup without consuming the plan',
    () async {
      final first = (await engine.status(repo)).head!;
      final second = await commit('b', 'next\n', 'second');
      final plan = await engine.inspect(
        repo,
        const GitInspection(GitInspectionKind.rebasePlan, root: true),
      );
      expect((plan['steps'] as List).map((e) => e['commit']), [
        first.value,
        second.value,
      ]);
      Future<GitOutcome> start(RebaseAction initial) => mutate(
        (s) => RebaseCommits(
          root: true,
          interactive: true,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
          planToken: plan['token'] as String,
          steps: [
            RebaseStep(initial, first),
            RebaseStep(RebaseAction.pick, second),
          ],
        ),
      );
      expect(
        (await start(RebaseAction.fixup)).error!.code,
        GitErrorCode.invalidRequest,
      );
      final outcome = await start(RebaseAction.reword);
      expect(outcome.completed, isTrue, reason: '${outcome.error}');
      expect(
        (await engine.history(repo)).commits.last.subject,
        'Reviewed message',
      );
    },
  );
  test(
    'merge preserving rebase retains the Git label/reset/merge structure and unrelated references',
    () async {
      final boundary = (await engine.status(repo)).head!;
      await git(['switch', '-c', 'side']);
      await commit('b', 'side\n', 'side');
      await git(['switch', 'main']);
      await commit('c', 'main\n', 'main');
      await git(['merge', '--no-ff', '--no-edit', 'side']);
      final unrelated = await git(['rev-parse', 'side']);
      await commit('d', 'after\n', 'after');
      final plan = await engine.inspect(
        repo,
        GitInspection(
          GitInspectionKind.rebasePlan,
          revision: boundary,
          preserveMerges: true,
        ),
      );
      expect(plan['todo'], contains('label '));
      expect(plan['todo'], contains('reset '));
      expect(plan['todo'], contains('merge -C '));
      final planned = (plan['steps'] as List).cast<Json>();
      expect(planned.map((s) => s['block']).toSet().length, greaterThan(1));
      final invalid = await mutate(
        (s) => RebaseCommits(
          boundary: boundary,
          preserveMerges: true,
          interactive: true,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
          planToken: plan['token'] as String,
          steps: [
            for (var i = 0; i < planned.length; i++)
              RebaseStep(
                i == 1 ? RebaseAction.fixup : RebaseAction.pick,
                GitOid(planned[i]['commit'] as String),
              ),
          ],
        ),
      );
      expect(invalid.error!.code, GitErrorCode.invalidRequest);
      final outcome = await mutate(
        (s) => RebaseCommits(
          boundary: boundary,
          preserveMerges: true,
          interactive: true,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
          planToken: plan['token'] as String,
          steps: (plan['steps'] as List)
              .map(
                (e) => RebaseStep(
                  RebaseAction.values.byName(e['action'] as String),
                  GitOid(e['commit'] as String),
                ),
              )
              .toList(),
        ),
      );
      expect(outcome.completed, isTrue, reason: '${outcome.error}');
      expect(
        (await engine.history(
          repo,
          filter: const HistoryFilter(reference: 'HEAD'),
        )).commits.where((c) => c.parents.length == 2),
        hasLength(1),
      );
      expect(await git(['rev-parse', 'side']), unrelated);
      expect(await File('${root.path}/b').readAsString(), 'side\n');
      expect(await File('${root.path}/c').readAsString(), 'main\n');
    },
  );
  test(
    'worktree create/remove, reflog and historical restore preserve bytes',
    () async {
      final start = (await engine.status(repo)).head!;
      final created = await mutate(
        (s) => WorktreeMutation(
          WorktreeAction.create,
          '${fixture.path}/linked',
          branch: 'linked',
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(created.completed, isTrue, reason: '${created.error}');
      final trees =
          (await engine.inspect(
                repo,
                const GitInspection(GitInspectionKind.worktrees),
              ))['entries']
              as List;
      expect(trees.length, 2);
      await File('${fixture.path}/linked/untracked').writeAsString('keep');
      final refused = await mutate(
        (s) => WorktreeMutation(
          WorktreeAction.remove,
          '${fixture.path}/linked',
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(refused.completed, isFalse);
      expect(
        await File('${fixture.path}/linked/untracked').readAsString(),
        'keep',
      );
      await commit('a', 'changed\r\n', 'change');
      final working = await engine.content(
        repo,
        RepoPath.text('a'),
        const ContentVersion.working(),
      );
      final restored = await mutate(
        (s) => RestorePaths(
          [RepoPath.text('a')],
          revision: start,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
          contentTokens: {RepoPath.text('a').key: working.token},
        ),
      );
      expect(restored.completed, isTrue);
      expect(await File('${root.path}/a').readAsBytes(), utf8.encode('base\n'));
      expect(
        ((await engine.inspect(
                  repo,
                  const GitInspection(GitInspectionKind.reflog),
                ))['entries']
                as List)
            .length,
        greaterThan(1),
      );
    },
  );
  test(
    'an already-applied cherry-pick can retain an explicit empty commit',
    () async {
      final tip = await commit('b', 'one\n', 'one');
      final stopped = await mutate(
        (s) => PickCommits(
          [tip],
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(stopped.phase, GitOperationPhase.stopped);
      expect(stopped.snapshot!.operation.kind, GitOperationKind.cherryPick);
      final tree = await git(['rev-parse', 'HEAD^{tree}']);
      final kept = await mutate(
        (s) => CommitIndex(
          'Retained empty application',
          allowEmpty: true,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(kept.completed, isTrue, reason: '${kept.error}');
      expect(kept.createdCommit, isNot(tip));
      expect(await git(['rev-parse', 'HEAD^{tree}']), tree);
      expect(await git(['rev-parse', 'HEAD^']), tip.value);
      expect((await engine.status(repo)).operation.kind, GitOperationKind.none);
    },
  );
  test(
    'a rebase commit that becomes empty can be kept and continued by Git',
    () async {
      final boundary = (await engine.status(repo)).head!;
      await git(['switch', '-c', 'topic']);
      final replayed = await commit('a', 'changed\n', 'replayed');
      await git(['switch', 'main']);
      await File('${root.path}/b').writeAsString('extra');
      await git(['add', 'b']);
      final onto = await commit(
        'a',
        'changed\n',
        'base with a superset of the replayed change',
      );
      await git(['switch', 'topic']);
      final stopped = await mutate(
        (s) => RebaseCommits(
          boundary: boundary,
          onto: onto,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(
        stopped.phase,
        GitOperationPhase.stopped,
        reason: '${stopped.error}',
      );
      expect(stopped.snapshot!.operation.other, replayed);
      final kept = await mutate(
        (s) => CommitIndex(
          'Retained empty rebase commit',
          allowEmpty: true,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(kept.createdCommit, isNotNull, reason: '${kept.error}');
      final done = await mutate(
        (s) => ContinueGitOperation(
          GitOperationKind.rebase,
          GitContinuation.continueOperation,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(done.completed, isTrue, reason: '${done.error}');
      expect(await git(['rev-parse', 'HEAD^']), onto.value);
      expect(
        await git(['log', '-1', '--format=%s']),
        'Retained empty rebase commit',
      );
    },
  );
}
