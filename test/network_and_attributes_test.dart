import 'dart:convert';
import 'dart:io';
import 'package:busystack_git/busystack_git.dart';
import 'package:test/test.dart';
import 'support/isolated_runner.dart';

void main() {
  late Directory fixture, root;
  late GitEngine engine;
  late RepositoryId repo;
  Future<String> git(
    List<String> arguments, {
    String? cwd,
    bool check = true,
  }) async {
    final result = await Process.run(
      '/usr/bin/git',
      arguments,
      workingDirectory: cwd ?? root.path,
      environment: {
        'HOME': '${fixture.path}/home',
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': '/dev/null',
        'GIT_AUTHOR_NAME': 'Fixture',
        'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
        'GIT_COMMITTER_NAME': 'Fixture',
        'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
      },
    );
    if (check && result.exitCode != 0)
      fail('${arguments.first}: ${result.stderr}');
    return (result.stdout as String).trimRight();
  }

  Future<GitOutcome> mutate(GitMutation Function(GitSnapshot) build) async =>
      engine.mutate(repo, build(await engine.status(repo)));
  Future<GitOid> commit(String content) async {
    await File('${root.path}/a.md').writeAsString(content);
    await git(['add', '.']);
    await git(['commit', '-m', content.trim()]);
    return GitOid(await git(['rev-parse', 'HEAD']));
  }

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('bsg-network-');
    root = await Directory('${fixture.path}/repo').create();
    await IsolatedGitRunner.prepare('${fixture.path}/home');
    await git(['init', '-b', 'feature']);
    await commit('base\n');
    engine = GitEngine(
      authorize: (_) => true,
      runner: IsolatedGitRunner('${fixture.path}/home'),
    );
    repo = (await engine.discover(root.path))!;
  });
  tearDown(() async => fixture.delete(recursive: true));
  test(
    'normalized partial staging respects CRLF and preserves working bytes and unrelated index',
    () async {
      await File(
        '${root.path}/.gitattributes',
      ).writeAsString('*.md text eol=crlf\n');
      await File(
        '${root.path}/a.md',
      ).writeAsBytes(utf8.encode('one\r\ntwo\r\nthree'));
      await git(['add', '.']);
      await git(['commit', '-m', 'attributes']);
      await File(
        '${root.path}/a.md',
      ).writeAsBytes(utf8.encode('ONE\r\ntwo\r\nTHREE'));
      await File('${root.path}/unrelated').writeAsString('retained');
      await git(['add', 'unrelated']);
      final path = RepoPath.text('a.md'), s = await engine.status(repo);
      final index = await engine.content(
        repo,
        path,
        const ContentVersion.index(),
      );
      final normalized = await engine.content(
        repo,
        path,
        const ContentVersion(ContentKind.normalizedWorking),
      );
      expect(normalized.text, 'ONE\ntwo\nTHREE');
      expect(normalized.sourceToken, isNotEmpty);
      final diff = computeTextDiff(index.text!, normalized.text!);
      final result = await engine.mutate(
        repo,
        WriteIndex(
          path,
          diff.select(diff.changedIndices.take(2).toSet()),
          expectedHead: s.head,
          expectedIndex: s.indexToken,
          expectedContent: index.token,
          expectedWorktree: normalized.sourceToken,
        ),
      );
      expect(result.completed, isTrue, reason: '${result.error}');
      expect(await git(['show', ':a.md']), 'ONE\ntwo\nthree');
      expect(
        await File('${root.path}/a.md').readAsBytes(),
        utf8.encode('ONE\r\ntwo\r\nTHREE'),
      );
      expect(await git(['show', ':unrelated']), 'retained');
    },
  );
  test(
    'push reviews actual distinct/multiple destinations, explicit tags, and rejects moved reviewed lease after fetch',
    () async {
      final remote = '${fixture.path}/remote.git',
          second = '${fixture.path}/second.git';
      await git(['init', '--bare', remote]);
      await git(['init', '--bare', second]);
      await git(['remote', 'add', 'publish', remote]);
      await git(['remote', 'set-url', '--push', '--add', 'publish', remote]);
      await git(['remote', 'set-url', '--push', '--add', 'publish', second]);
      await git(['tag', '-a', 'v1', '-m', 'Reviewed tag']);
      var plan = await engine.inspect(
        repo,
        const GitInspection(
          GitInspectionKind.pushReview,
          remote: 'publish',
          destination: 'refs/heads/feature',
          tags: ['refs/tags/v1'],
        ),
      );
      expect((plan['destinations'] as List).length, 2);
      final pushed = await mutate(
        (s) => PushReviewed(
          plan['token'] as String,
          tags: const ['refs/tags/v1'],
          setUpstream: true,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(pushed.completed, isTrue, reason: '${pushed.error}');
      expect(
        await git(['rev-parse', 'refs/heads/feature'], cwd: remote),
        (await engine.status(repo)).head!.value,
      );
      expect(
        await git(['rev-parse', 'refs/tags/v1'], cwd: second),
        await git(['rev-parse', 'refs/tags/v1']),
      );
      final reviewedTip = (await engine.status(repo)).head!;
      await commit('local rewrite\n');
      plan = await engine.inspect(
        repo,
        const GitInspection(
          GitInspectionKind.pushReview,
          remote: 'publish',
          destination: 'refs/heads/feature',
        ),
      );
      await git(['clone', remote, '${fixture.path}/other']);
      await git(['switch', 'feature'], cwd: '${fixture.path}/other');
      await File('${fixture.path}/other/new').writeAsString('someone else');
      await git(['add', '.'], cwd: '${fixture.path}/other');
      await git([
        'commit',
        '-m',
        'External update',
      ], cwd: '${fixture.path}/other');
      await git(['push', 'origin', 'feature'], cwd: '${fixture.path}/other');
      final serverTip = await git([
        'rev-parse',
        'refs/heads/feature',
      ], cwd: remote);
      expect(serverTip, isNot(reviewedTip.value));
      await git([
        'fetch',
        'publish',
      ]); // background fetch must not renew consent
      final refused = await mutate(
        (s) => PushReviewed(
          plan['token'] as String,
          forceWithLease: true,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(refused.completed, isFalse);
      expect(refused.error!.code, GitErrorCode.rejected);
      expect(
        await git(['rev-parse', 'refs/heads/feature'], cwd: remote),
        serverTip,
      );
    },
  );
  test(
    'ff-only pull never falls back; configured signing/hook behavior is honored',
    () async {
      final remote = '${fixture.path}/remote.git';
      await git(['init', '--bare', remote]);
      await git(['remote', 'add', 'upstream', remote]);
      await git(['push', '-u', 'upstream', 'feature']);
      await git([
        'clone',
        '--branch',
        'feature',
        remote,
        '${fixture.path}/other',
      ]);
      await File('${fixture.path}/other/other').writeAsString('remote');
      await git(['add', '.'], cwd: '${fixture.path}/other');
      await git(['commit', '-m', 'remote'], cwd: '${fixture.path}/other');
      await git(['push'], cwd: '${fixture.path}/other');
      final local = await commit('local\n');
      final rejected = await mutate(
        (s) => PullRemote(
          'upstream',
          'feature',
          PullStrategy.fastForwardOnly,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(rejected.completed, isFalse);
      expect((await engine.status(repo)).head, local);
      expect((await engine.status(repo)).operation.kind, GitOperationKind.none);
      final key = '${fixture.path}/signing';
      final keygen = await Process.run('/usr/bin/ssh-keygen', [
        '-t',
        'ed25519',
        '-N',
        '',
        '-f',
        key,
      ]);
      expect(keygen.exitCode, 0);
      await git(['config', 'gpg.format', 'ssh']);
      await git(['config', 'user.signingkey', key]);
      await git(['config', 'commit.gpgsign', 'true']);
      final allowed = File('${fixture.path}/allowed');
      await allowed.writeAsString(
        'fixture@example.invalid ${await File('$key.pub').readAsString()}',
      );
      await git(['config', 'gpg.ssh.allowedSignersFile', allowed.path]);
      await File('${root.path}/signed').writeAsString('signed');
      await git(['add', 'signed']);
      final signed = await mutate(
        (s) => CommitIndex(
          'signed',
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(signed.completed, isTrue, reason: '${signed.error}');
      await git(['verify-commit', 'HEAD']);
      final hook = File('${repo.gitDir}/hooks/pre-commit');
      await hook.writeAsString('#!/bin/sh\nexit 1\n');
      await Process.run('/bin/chmod', ['0700', hook.path]);
      await File('${root.path}/rejected').writeAsString('not committed');
      await git(['add', 'rejected']);
      final before = (await engine.status(repo)).head;
      final blocked = await mutate(
        (s) => CommitIndex(
          'hook rejected',
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(blocked.completed, isFalse);
      expect((await engine.status(repo)).head, before);
      expect(await git(['show', ':rejected']), 'not committed');
    },
  );
  test(
    'paging a push review keeps its original source and expected remote tip',
    () async {
      final remote = '${fixture.path}/paged.git';
      await git(['init', '--bare', remote]);
      await git(['remote', 'add', 'publish', remote]);
      await git(['push', 'publish', 'feature']);
      for (var i = 0; i < 6; i++) {
        await commit('reviewed $i\n');
      }
      final review = await engine.inspect(
        repo,
        const GitInspection(
          GitInspectionKind.pushReview,
          remote: 'publish',
          destination: 'refs/heads/feature',
          limit: 2,
        ),
      );
      final first =
          ((review['outgoing'] as List).single as Json)['commits'] as List;
      expect(first.length, 2);
      expect(review['hasMore'], isTrue);
      final reviewedSource = review['source'];
      await git([
        'clone',
        '--branch',
        'feature',
        remote,
        '${fixture.path}/other',
      ]);
      await File('${fixture.path}/other/external').writeAsString('external');
      await git(['add', '.'], cwd: '${fixture.path}/other');
      await git(['commit', '-m', 'external'], cwd: '${fixture.path}/other');
      await git(['push'], cwd: '${fixture.path}/other');
      final serverTip = await git([
        'rev-parse',
        'refs/heads/feature',
      ], cwd: remote);
      await git(['fetch', 'publish']);
      await commit('created after review\n');
      final next = await engine.inspect(
        repo,
        GitInspection(
          GitInspectionKind.pushPage,
          reviewToken: review['token'] as String,
          offset: 2,
          limit: 2,
        ),
      );
      final second =
          ((next['outgoing'] as List).single as Json)['commits'] as List;
      expect(next['token'], review['token']);
      expect(second.length, 2);
      final expected = (await git([
        'log',
        '--format=%H',
        '--max-count=2',
        '--skip=2',
        reviewedSource as String,
      ])).split('\n');
      expect(second.cast<Json>().map((c) => c['oid']), expected);
      expect(
        first
            .cast<Json>()
            .map((c) => c['oid'])
            .toSet()
            .intersection(second.cast<Json>().map((c) => c['oid']).toSet()),
        isEmpty,
      );
      final refused = await mutate(
        (s) => PushReviewed(
          review['token'] as String,
          forceWithLease: true,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(refused.completed, isFalse);
      expect(
        await git(['rev-parse', 'refs/heads/feature'], cwd: remote),
        serverTip,
      );
    },
  );
  test(
    'clone and init distinguish preexisting destinations without overwriting or initial commits',
    () async {
      final target = '${fixture.path}/clone';
      final cloned = await engine.create(CloneRepository(root.path, target));
      expect(
        cloned.phase,
        GitOperationPhase.completed,
        reason: '${cloned.error}',
      );
      expect(cloned.createdDirectory, isTrue);
      await File('$target/keep').writeAsString('user');
      final repeated = await engine.create(CloneRepository(root.path, target));
      expect(repeated.phase, GitOperationPhase.failed);
      expect(repeated.createdDirectory, isFalse);
      expect(await File('$target/keep').readAsString(), 'user');
      final directory = await Directory('${fixture.path}/initialized').create();
      await File('${directory.path}/existing').writeAsString('existing');
      final initialized = await engine.create(
        InitializeRepository(directory.path, initialBranch: 'writing'),
      );
      expect(initialized.phase, GitOperationPhase.completed);
      final state = await engine.status(initialized.repository!);
      expect(state.head, isNull);
      expect(state.branch, 'writing');
      expect(state.changes.single.untracked, isTrue);
      final bare = '${fixture.path}/existing-bare';
      await git(['clone', '--bare', root.path, bare]);
      final config = await File('$bare/config').readAsBytes();
      final refused = await engine.create(InitializeRepository(bare));
      expect(refused.error!.code, GitErrorCode.invalidRequest);
      expect(await File('$bare/config').readAsBytes(), config);
      expect(await Directory('$bare/.git').exists(), isFalse);
    },
  );
}
