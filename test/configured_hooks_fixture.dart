// Explicit current-Git fixture: BUSYSTACK_TEST_GIT_256=/absolute/git
// dart test test/configured_hooks_fixture.dart. Missing prerequisites fail.
import 'dart:io';
import 'package:busystack_git/busystack_git.dart';
import 'package:test/test.dart';
import 'support/isolated_runner.dart';

void main() {
  test(
    'Git 2.56 configuration hooks are inventoried, passive-safe and honored',
    () async {
      final executable = Platform.environment['BUSYSTACK_TEST_GIT_256'];
      expect(
        executable,
        isNotNull,
        reason: 'Provide the verified isolated Git 2.56 executable.',
      );
      final fixture = await Directory.systemTemp.createTemp(
        'bsg-config-hooks-',
      );
      addTearDown(() => fixture.delete(recursive: true));
      final runner = IsolatedGitRunner(
        '${fixture.path}/home',
        executable: executable,
      );
      await IsolatedGitRunner.prepare('${fixture.path}/home');
      Future<GitRunResult> command(List<String> args) => runner.run(
        args,
        cwd: fixture.path,
        deadline: const Duration(seconds: 10),
      );
      final version = await command(['--version']);
      expect(version.text, contains('2.56.'));
      expect((await command(['init', '-b', 'feature'])).success, isTrue);
      final marker = '${fixture.path}/hook-executed';
      await command([
        'config',
        'hook.fixture.command',
        'printf configured-hook > "$marker"',
      ]);
      await command(['config', 'hook.fixture.event', 'pre-commit']);
      await File('${fixture.path}/document').writeAsString('stage me');
      final engine = GitEngine(runner: runner, authorize: (_) => true),
          repo = (await GitEngine(runner: runner).discover(fixture.path))!;
      var snapshot = await engine.status(repo);
      expect(await File(marker).exists(), isFalse);
      final options = await engine.inspect(
        repo,
        const GitInspection(GitInspectionKind.commitOptions),
      );
      expect(
        options['hooks'] as List,
        contains(contains('pre-commit: local\tfixture')),
      );
      expect(options['activeCommitHookEvents'], contains('pre-commit'));
      expect(await File(marker).exists(), isFalse);
      await command(['config', 'hook.fixture.enabled', 'false']);
      final disabled = await engine.inspect(
        repo,
        const GitInspection(GitInspectionKind.commitOptions),
      );
      expect(disabled['activeCommitHookEvents'], isNot(contains('pre-commit')));
      await command(['config', 'hook.fixture.enabled', 'true']);
      await engine.mutate(
        repo,
        StagePaths(
          [RepoPath.text('document')],
          expectedHead: snapshot.head,
          expectedIndex: snapshot.indexToken,
        ),
      );
      snapshot = await engine.status(repo);
      final committed = await engine.mutate(
        repo,
        CommitIndex(
          'configuration hook',
          expectedHead: snapshot.head,
          expectedIndex: snapshot.indexToken,
        ),
      );
      expect(committed.completed, isTrue, reason: '${committed.error}');
      expect(await File(marker).readAsString(), 'configured-hook');
      await command(['config', 'hook.fixture.command', 'exit 1']);
      await File('${fixture.path}/document').writeAsString('rejected');
      await command(['add', '.']);
      snapshot = await engine.status(repo);
      final rejected = await engine.mutate(
        repo,
        CommitIndex(
          'must not commit',
          expectedHead: snapshot.head,
          expectedIndex: snapshot.indexToken,
        ),
      );
      expect(rejected.completed, isFalse);
      expect((await engine.status(repo)).head, snapshot.head);
    },
  );
}
