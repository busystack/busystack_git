import 'dart:convert';
import 'dart:io';
import 'package:busystack_git/busystack_git.dart';
import 'package:test/test.dart';
import 'support/repository_fixture.dart';

void main() {
  late RepositoryFixture fixture;
  setUp(() async => fixture = await RepositoryFixture.create());
  tearDown(() => fixture.close());

  test(
    'pull review reads branch policy and complete configured remote names',
    () async {
      await fixture.commit('base.md', utf8.encode('Base\n'), 'Base');
      await fixture.git(['branch', '-m', 'topic.with.dots']);
      await fixture.git(['tag', 'topic.with.dots']);
      await fixture.git(['config', 'pull.rebase', 'true']);
      await fixture.git(['config', 'branch.topic.with.dots.rebase', 'false']);
      await fixture.git(['config', 'pull.ff', 'false']);
      await fixture.git([
        'config',
        'branch.topic.with.dots.remote',
        'team/upstream',
      ]);
      await fixture.git([
        'config',
        'branch.topic.with.dots.merge',
        'refs/heads/review/main',
      ]);
      await fixture.git(['config', 'remote.pushDefault', 'company/publish']);
      await fixture.git([
        'config',
        'branch.topic.with.dots.pushRemote',
        'my/publish',
      ]);
      final options = await fixture.engine.inspect(
        fixture.repository,
        const GitInspection(GitInspectionKind.commitOptions),
      );
      expect(options['upstreamRemote'], 'team/upstream');
      expect(options['upstreamBranch'], 'refs/heads/review/main');
      expect(options['pushRemote'], 'my/publish');
      expect(options['pullRebase'], 'false');
      expect(options['pullFf'], 'false');
      expect(await fixture.git(['config', 'pull.rebase']), 'true');
    },
  );

  Future<String> publishBase() async {
    await fixture.commit('base.md', utf8.encode('Base\n'), 'Base');
    final remote = '${fixture.directory.path}/remote.git';
    await fixture.git(['init', '--bare', remote]);
    await fixture.git(['remote', 'add', 'team/upstream', remote]);
    await fixture.git(['push', '--set-upstream', 'team/upstream', 'main']);
    final writer = '${fixture.directory.path}/writer';
    await fixture.git(['clone', '--branch', 'main', remote, writer]);
    await File('$writer/remote.md').writeAsString('Remote prose\n');
    await fixture.git(['add', 'remote.md'], cwd: writer);
    await fixture.git(['commit', '-m', 'Remote prose'], cwd: writer);
    await fixture.git(['push', 'origin', 'main'], cwd: writer);
    return fixture.git(['rev-parse', 'HEAD'], cwd: writer);
  }

  test(
    'reviewed merge pull creates a merge commit when fast-forward was possible',
    () async {
      final remoteTip = await publishBase();
      final old = (await fixture.engine.status(fixture.repository)).head!;
      final result = await fixture.mutate(
        (state) => PullRemote(
          'team/upstream',
          'main',
          PullStrategy.merge,
          expectedHead: state.head,
          expectedIndex: state.indexToken,
          noFastForward: true,
        ),
      );
      expect(result.completed, isTrue, reason: '${result.error}');
      expect(await fixture.git(['rev-parse', 'HEAD^1']), old.value);
      expect(await fixture.git(['rev-parse', 'HEAD^2']), remoteTip);
      expect(
        await File('${fixture.root.path}/remote.md').readAsString(),
        'Remote prose\n',
      );
    },
  );

  test(
    'reviewed rebase pull preserves local merge parents and wire intent',
    () async {
      final remoteTip = await publishBase();
      await fixture.git(['switch', '-c', 'side']);
      await fixture.commit('side.md', utf8.encode('Side\n'), 'Side');
      await fixture.git(['switch', 'main']);
      await fixture.commit('main.md', utf8.encode('Main\n'), 'Main');
      await fixture.git(['merge', '--no-ff', 'side', '-m', 'Local merge']);
      final state = await fixture.engine.status(fixture.repository);
      final request = PullRemote(
        'team/upstream',
        'main',
        PullStrategy.rebase,
        expectedHead: state.head,
        expectedIndex: state.indexToken,
        preserveMerges: true,
      );
      final decoded = decodeGitMutation(request.toJson()) as PullRemote;
      expect(decoded.preserveMerges, isTrue);
      expect(decoded.noFastForward, isFalse);
      final result = await fixture.engine.mutate(fixture.repository, decoded);
      expect(result.completed, isTrue, reason: '${result.error}');
      expect(await fixture.git(['rev-parse', 'team/upstream/main']), remoteTip);
      expect(
        await fixture.git([
          'rev-list',
          '--count',
          '--merges',
          'team/upstream/main..HEAD',
        ]),
        '1',
      );
      expect(
        (await fixture.git(['show', '-s', '--format=%P', 'HEAD'])).split(' '),
        hasLength(2),
      );
      expect(
        await File('${fixture.root.path}/side.md').readAsString(),
        'Side\n',
      );
      expect(
        await File('${fixture.root.path}/main.md').readAsString(),
        'Main\n',
      );
      expect(
        await File('${fixture.root.path}/remote.md').readAsString(),
        'Remote prose\n',
      );
    },
  );
}
