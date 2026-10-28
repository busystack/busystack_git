import 'dart:io';
import 'package:busystack_git/busystack_git.dart';
import 'isolated_runner.dart';

final class RepositoryFixture {
  RepositoryFixture._(this.directory, this.root, this.engine);
  final Directory directory, root;
  final GitEngine engine;
  late RepositoryId repository;
  String get home => '${directory.path}/home';
  Map<String, String> get environment => {
    'HOME': home,
    'XDG_CONFIG_HOME': home,
    'PATH': '/usr/bin:/bin',
    'GIT_CONFIG_NOSYSTEM': '1',
    'GIT_CONFIG_GLOBAL': '/dev/null',
    'GIT_AUTHOR_NAME': 'Fixture',
    'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
    'GIT_COMMITTER_NAME': 'Fixture',
    'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
  };
  static Future<RepositoryFixture> create({
    String objectFormat = 'sha1',
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'busystack-git-semantics-',
    );
    final root = await Directory('${directory.path}/repo').create();
    final home = '${directory.path}/home';
    await IsolatedGitRunner.prepare(home);
    final fixture = RepositoryFixture._(
      directory,
      root,
      GitEngine(runner: IsolatedGitRunner(home), authorize: (_) => true),
    );
    await fixture.git(['init', '-b', 'main', '--object-format=$objectFormat']);
    fixture.repository = (await fixture.engine.discover(root.path))!;
    return fixture;
  }

  Future<ProcessResult> run(List<String> args, {String? cwd}) => Process.run(
    Platform.environment['BUSYSTACK_TEST_GIT'] ?? '/usr/bin/git',
    args,
    workingDirectory: cwd ?? root.path,
    includeParentEnvironment: false,
    environment: environment,
  );
  Future<String> git(List<String> args, {String? cwd}) async {
    final result = await run(args, cwd: cwd);
    if (result.exitCode != 0)
      throw StateError('${args.first}: ${result.stderr}');
    return (result.stdout as String).trimRight();
  }

  Future<GitOid> commit(String path, List<int> bytes, String message) async {
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    await git(['add', '--', path]);
    await git(['commit', '-m', message]);
    return GitOid(await git(['rev-parse', 'HEAD']));
  }

  Future<GitOutcome> mutate(GitMutation Function(GitSnapshot) build) async {
    final state = await engine.status(repository);
    return engine.mutate(repository, build(state));
  }

  Future<void> close() => directory.delete(recursive: true);
}
