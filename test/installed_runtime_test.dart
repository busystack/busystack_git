import 'dart:io';
import 'package:busystack_git/busystack_git.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'support/isolated_runner.dart';

void main() {
  test(
    'moved packaged runtime finds its defaults and honors configured init templates',
    () async {
      final fixture = await Directory.systemTemp.createTemp(
        'bsg-installed-runtime-',
      );
      addTearDown(() => fixture.delete(recursive: true));
      final selected = Platform.environment['BUSYSTACK_TEST_GIT'];
      if (selected == null || !selected.endsWith('/git-runtime/bin/git')) {
        throw StateError(
          'Build tool/build_runtime.py and set BUSYSTACK_TEST_GIT to its git-runtime/bin/git for installed-runtime verification.',
        );
      }
      final original = p.dirname(p.dirname(selected));
      final moved = '${fixture.path}/moved/git-runtime';
      await Directory(p.dirname(moved)).create();
      final copied = await Process.run('/bin/cp', ['-a', original, moved]);
      expect(copied.exitCode, 0, reason: '${copied.stderr}');
      final home = '${fixture.path}/home';
      await IsolatedGitRunner.prepare(home);
      final executable = '$moved/bin/git';
      final environment = {
        'PATH': '/usr/bin:/bin',
        'HOME': home,
        'XDG_CONFIG_HOME': home,
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': '/dev/null',
      };
      // No runner environment overrides may conceal compiled-in build paths.
      final execPath = await Process.run(
        executable,
        ['--exec-path'],
        includeParentEnvironment: false,
        environment: environment,
      );
      expect(execPath.exitCode, 0);
      expect((execPath.stdout as String).trim(), '$moved/libexec/git-core');

      final templates = await Directory(
        '${fixture.path}/configured-template',
      ).create();
      const description = [0xef, 0xbb, 0xbf, 0x43, 0x52, 0x0d, 0x0a];
      await File('${templates.path}/description').writeAsBytes(description);
      final global = File('$home/private-git-config');
      await global.writeAsString(
        '[init]\n defaultBranch = writing\n templateDir = ${templates.path}\n',
      );
      final engine = GitEngine(
        runner: IsolatedGitRunner(
          home,
          executable: executable,
          globalConfig: global.path,
        ),
        authorize: (_) => true,
      );
      final target = await Directory('${fixture.path}/writing').create();
      await File(
        '${target.path}/notes.md',
      ).writeAsString('Leave these authoring bytes alone.\n');
      final configured = await engine.create(InitializeRepository(target.path));
      expect(
        configured.phase,
        GitOperationPhase.completed,
        reason: '${configured.error}',
      );
      expect(
        await File('${target.path}/.git/description').readAsBytes(),
        description,
      );
      final state = await engine.status(configured.repository!);
      expect(state.branch, 'writing');
      expect(state.head, isNull);
      expect(state.changes.single.untracked, isTrue);
      expect(
        await File('${target.path}/notes.md').readAsString(),
        'Leave these authoring bytes alone.\n',
      );

      // With no configured template, use the bundled defaults at the new path.
      await global.writeAsString('[init]\n defaultBranch = writing\n');
      final defaults = await engine.create(
        InitializeRepository('${fixture.path}/defaults'),
      );
      expect(
        defaults.phase,
        GitOperationPhase.completed,
        reason: '${defaults.error}',
      );
      expect(
        await File(
          '${fixture.path}/defaults/.git/hooks/pre-commit.sample',
        ).exists(),
        isTrue,
      );
      expect((await engine.status(defaults.repository!)).head, isNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
