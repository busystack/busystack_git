import 'dart:convert';
import 'dart:io';
import 'package:busystack_git/busystack_git.dart';
import 'package:test/test.dart';
import 'support/isolated_runner.dart';
import 'support/repository_fixture.dart';

void main() {
  late RepositoryFixture f;
  setUp(() async => f = await RepositoryFixture.create());
  tearDown(() => f.close());
  Future<GitOid> base() => f.commit('a', utf8.encode('Original\n'), 'Base');
  Future<void> stage() async {
    await File('${f.root.path}/a').writeAsString('Reviewed\n');
    await f.git(['add', 'a']);
  }

  Future<void> hook(String name, String body) async {
    final file = File('${f.repository.gitDir}/hooks/$name');
    await file.writeAsString(
      '#!/usr/bin/python3\nimport subprocess, pathlib, sys\n$body\n',
    );
    await Process.run('/bin/chmod', ['0700', file.path]);
  }

  String getGit() => Platform.environment['BUSYSTACK_TEST_GIT']!;

  for (final format in ['sha1', 'sha256']) {
    test(
      'confirmed initial $format commit records its actual object and cleans its handoff',
      () async {
        if (format == 'sha256') {
          await f.close();
          f = await RepositoryFixture.create(objectFormat: format);
        }
        await stage();
        String? handoff;
        final engine = GitEngine(
          runner: IsolatedGitRunner(
            f.home,
            beforeRun: (args, env) async {
              if (args.contains('commit'))
                handoff = env['BUSYSTACK_GIT_RECEIPT_PATH'];
            },
          ),
          authorize: (_) => true,
        );
        final state = await engine.status(f.repository);
        final config = await File(
          '${f.repository.gitDir}/config',
        ).readAsBytes();
        final result = await engine.mutate(
          f.repository,
          CommitIndex(
            'Initial review',
            expectedHead: state.head,
            expectedIndex: state.indexToken,
          ),
        );
        expect(result.completed, isTrue, reason: '${result.error}');
        expect(result.createdCommit!.value, await f.git(['rev-parse', 'HEAD']));
        expect(result.createdCommit!.value.length, format == 'sha1' ? 40 : 64);
        expect(await f.git(['show', 'HEAD:a']), 'Reviewed');
        expect(
          await File('${f.repository.gitDir}/config').readAsBytes(),
          config,
        );
        expect(handoff, isNotNull);
        expect(await Directory(File(handoff!).parent.path).exists(), isFalse);
      },
    );
  }

  for (final detached in [false, true]) {
    test(
      'pre-commit cannot redirect the reviewed target (detached=$detached)',
      () async {
        final original = await base();
        await f.git(['branch', 'other']);
        if (detached) await f.git(['switch', '--detach']);
        await stage();
        final index = await File('${f.repository.gitDir}/index').readAsBytes();
        await hook(
          'pre-commit',
          'subprocess.run(["/usr/bin/git", "symbolic-ref", "HEAD", "refs/heads/other"], check=True)',
        );
        final result = await f.mutate(
          (state) => CommitIndex(
            'Reviewed for original target',
            expectedHead: state.head,
            expectedIndex: state.indexToken,
          ),
        );
        expect(
          result.error?.code,
          GitErrorCode.staleReview,
          reason: '${result.error}',
        );
        expect(result.createdCommit, isNull);
        expect(await f.git(['rev-parse', 'refs/heads/main']), original.value);
        expect(await f.git(['rev-parse', 'refs/heads/other']), original.value);
        // Preserve the hook's side effect; do not reset another client's HEAD.
        expect(await f.git(['symbolic-ref', 'HEAD']), 'refs/heads/other');
        expect(await File('${f.repository.gitDir}/index').readAsBytes(), index);
        expect(await File('${f.root.path}/a').readAsString(), 'Reviewed\n');
      },
    );
  }

  test(
    'a real preparing reference hook cannot retarget the commit before refs lock',
    () async {
      final original = await base();
      await f.git(['branch', 'other']);
      await stage();
      final marker = '${f.directory.path}/switched';
      await hook('reference-transaction', '''
if sys.argv[1] == 'preparing' and not pathlib.Path(${jsonEncode(marker)}).exists():
 pathlib.Path(${jsonEncode(marker)}).write_text('switched')
 subprocess.run(['/usr/bin/git', 'symbolic-ref', 'HEAD', 'refs/heads/other'], check=True)
sys.stdin.buffer.read()
''');
      final result = await f.mutate(
        (state) => CommitIndex(
          'Bound transaction',
          expectedHead: state.head,
          expectedIndex: state.indexToken,
        ),
      );
      expect(
        result.error?.code,
        GitErrorCode.staleReview,
        reason: '${result.error}',
      );
      expect(result.createdCommit, isNull);
      expect(await f.git(['rev-parse', 'refs/heads/main']), original.value);
      expect(await f.git(['rev-parse', 'refs/heads/other']), original.value);
    },
  );

  test(
    'post-commit Git commands run normally without replacing the owning receipt',
    () async {
      await base();
      await stage();
      await hook(
        'post-commit',
        'subprocess.run([${jsonEncode(getGit())}, "update-ref", "refs/heads/mirror", "HEAD"], check=True)',
      );
      final result = await f.mutate(
        (state) => CommitIndex(
          'User hook retained',
          expectedHead: state.head,
          expectedIndex: state.indexToken,
        ),
      );
      expect(result.completed, isTrue, reason: '${result.error}');
      expect(result.createdCommit!.value, await f.git(['rev-parse', 'HEAD']));
      expect(
        await f.git(['rev-parse', 'refs/heads/mirror']),
        result.createdCommit!.value,
      );
    },
  );

  test(
    'a post-commit HEAD switch reports the actual local commit instead of the current tip',
    () async {
      final original = await base();
      await f.git(['branch', 'other']);
      await stage();
      await hook(
        'post-commit',
        'subprocess.run([${jsonEncode(getGit())}, "symbolic-ref", "HEAD", "refs/heads/other"], check=True)',
      );
      final result = await f.mutate(
        (state) => CommitIndex(
          'Actual reviewed commit',
          expectedHead: state.head,
          expectedIndex: state.indexToken,
        ),
      );
      expect(
        result.phase,
        GitOperationPhase.uncertain,
        reason: '${result.error}',
      );
      expect(
        result.createdCommit!.value,
        await f.git(['rev-parse', 'refs/heads/main']),
      );
      expect(result.createdCommit!.value, isNot(original.value));
      expect(result.snapshot!.head, original);
      expect(await f.git(['symbolic-ref', 'HEAD']), 'refs/heads/other');
      expect(
        await f.git(['show', '${result.createdCommit!.value}:a']),
        'Reviewed',
      );
    },
  );

  test(
    'post-commit creating a second commit does not claim that second object as the reviewed commit',
    () async {
      await base();
      await stage();
      final marker = '${f.directory.path}/hook-ran';
      await hook('post-commit', '''
marker = pathlib.Path(${jsonEncode(marker)})
if not marker.exists():
 marker.write_text('ran')
 subprocess.run([${jsonEncode(getGit())}, 'commit', '--allow-empty', '-m', 'Hook commit'], check=True)
''');
      final result = await f.mutate(
        (state) => CommitIndex(
          'Reviewed commit',
          expectedHead: state.head,
          expectedIndex: state.indexToken,
        ),
      );
      expect(
        result.phase,
        GitOperationPhase.uncertain,
        reason: '${result.error}',
      );
      expect(result.createdCommit!.value, await f.git(['rev-parse', 'HEAD^']));
      expect(result.snapshot!.head!.value, await f.git(['rev-parse', 'HEAD']));
      expect(result.createdCommit, isNot(result.snapshot!.head));
    },
  );

  test(
    'substituted outcome paths cannot write another file or create a commit',
    () async {
      final original = await base();
      await stage();
      final target = File('${f.directory.path}/unrelated')
        ..writeAsStringSync('Keep these bytes');
      String? handoff;
      final engine = GitEngine(
        runner: IsolatedGitRunner(
          f.home,
          beforeRun: (args, env) async {
            if (!args.contains('commit')) return;
            handoff = env['BUSYSTACK_GIT_RECEIPT_PATH'];
            await File(handoff!).delete();
            await Link(handoff!).create(target.path);
          },
        ),
        authorize: (_) => true,
      );
      final state = await engine.status(f.repository);
      final entries = await f.git(['ls-files', '--stage']);
      final result = await engine.mutate(
        f.repository,
        CommitIndex(
          'Reject substitution',
          expectedHead: state.head,
          expectedIndex: state.indexToken,
        ),
      );
      expect(result.completed, isFalse);
      expect(result.error?.code, GitErrorCode.unsafePath);
      expect(result.createdCommit, isNull);
      expect(await f.git(['rev-parse', 'HEAD']), original.value);
      expect(await f.git(['ls-files', '--stage']), entries);
      expect(await target.readAsString(), 'Keep these bytes');
      expect(await Directory(File(handoff!).parent.path).exists(), isFalse);
    },
  );

  test(
    'a symbolic branch alias commits to the reviewed final reference',
    () async {
      await base();
      await f.git(['symbolic-ref', 'refs/heads/alias', 'refs/heads/main']);
      await f.git(['symbolic-ref', 'HEAD', 'refs/heads/alias']);
      await stage();
      final result = await f.mutate(
        (state) => CommitIndex(
          'Reviewed symbolic branch',
          expectedHead: state.head,
          expectedIndex: state.indexToken,
        ),
      );
      expect(result.completed, isTrue, reason: '${result.error}');
      expect(
        result.createdCommit!.value,
        await f.git(['rev-parse', 'refs/heads/main']),
      );
      expect(
        await f.git(['symbolic-ref', '--no-recurse', 'HEAD']),
        'refs/heads/alias',
      );
    },
  );

  test(
    'a disabled reference hook event requires review without changing configuration',
    () async {
      final original = await base();
      await stage();
      await f.git(['config', 'hook.reference-transaction.enabled', 'false']);
      final config = await File('${f.repository.gitDir}/config').readAsBytes();
      final result = await f.mutate(
        (state) => CommitIndex(
          'Requires reference guard',
          expectedHead: state.head,
          expectedIndex: state.indexToken,
        ),
      );
      expect(result.completed, isFalse);
      expect(result.error?.code, GitErrorCode.invalidRequest);
      expect(result.createdCommit, isNull);
      expect(await f.git(['rev-parse', 'HEAD']), original.value);
      expect(await File('${f.repository.gitDir}/config').readAsBytes(), config);
      expect(await f.git(['show', ':a']), 'Reviewed');
    },
  );
}
