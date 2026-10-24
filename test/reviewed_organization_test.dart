import 'dart:convert';
import 'dart:io';
import 'package:busystack_git/busystack_git.dart';
import 'package:test/test.dart';
import 'support/isolated_runner.dart';
import 'support/repository_fixture.dart';

void main() {
  late RepositoryFixture f;
  setUp(() async => f = await RepositoryFixture.create());
  tearDown(() async => f.close());

  Future<RepoPath> addModule() async {
    final source = await Directory('${f.directory.path}/module').create();
    await f.git(['init', '-b', 'main'], cwd: source.path);
    await File('${source.path}/a').writeAsString('module bytes\n');
    await f.git(['add', '.'], cwd: source.path);
    await f.git(['commit', '-m', 'module'], cwd: source.path);
    await f.git([
      '-c',
      'protocol.file.allow=always',
      'submodule',
      'add',
      source.path,
      'nested',
    ]);
    await f.git(['commit', '-m', 'add submodule']);
    return RepoPath.text('nested');
  }

  test(
    'submodule commits with identical status flags invalidate review and pointer staging',
    () async {
      final path = await addModule(), child = '${f.root.path}/nested';
      final recorded = await f.git(['rev-parse', ':nested']);
      await f.git([
        'commit',
        '--allow-empty',
        '-m',
        'first child tip',
      ], cwd: child);
      final reviewed = await f.engine.status(f.repository);
      final source = await f.engine.content(
        f.repository,
        path,
        const ContentVersion.working(),
      );
      await f.git([
        'commit',
        '--allow-empty',
        '-m',
        'second child tip',
      ], cwd: child);
      final current = await f.engine.status(f.repository);
      expect(
        current.changes.single.submodule,
        reviewed.changes.single.submodule,
      );
      expect(current.indexToken, reviewed.indexToken);
      expect(current.token, isNot(reviewed.token));
      final stage = await f.engine.mutate(
        f.repository,
        StagePaths(
          [path],
          expectedHead: reviewed.head,
          expectedIndex: reviewed.indexToken,
          expectedSnapshot: reviewed.token,
        ),
      );
      expect(stage.error!.code, GitErrorCode.staleReview);
      final stale = SubmoduleMutation(
        SubmoduleAction.stagePointer,
        [path],
        expectedHead: current.head,
        expectedIndex: current.indexToken,
        contentTokens: {path.key: source.token},
      );
      final decoded = decodeGitMutation(stale.toJson()) as SubmoduleMutation;
      expect(decoded.contentTokens, stale.contentTokens);
      final outcome = await f.engine.mutate(f.repository, decoded);
      expect(outcome.error!.code, GitErrorCode.staleReview);
      expect(await f.git(['rev-parse', ':nested']), recorded);
      expect(await File('$child/a').readAsString(), 'module bytes\n');
    },
  );

  test(
    'a reviewed worktree path cannot authorize a replacement checkout',
    () async {
      await f.commit('a', utf8.encode('parent bytes'), 'base');
      final path = '${f.directory.path}/linked';
      await f.git(['worktree', 'add', '-b', 'linked', path]);
      final row =
          ((await f.engine.inspect(
                    f.repository,
                    const GitInspection(GitInspectionKind.worktrees),
                  ))['entries']
                  as List)
              .cast<Json>()
              .singleWhere((row) => row['path'] == path);
      await f.git(['worktree', 'remove', path]);
      await f.git(['worktree', 'add', path, 'linked']);
      await File('$path/owned').writeAsString('replacement data');
      final state = await f.engine.status(f.repository);
      final request = WorktreeMutation(
        WorktreeAction.remove,
        path,
        forceReviewed: true,
        expectedHead: state.head,
        expectedIndex: state.indexToken,
        expectedTargetToken: row['reviewToken'] as String,
      );
      final decoded = decodeGitMutation(request.toJson()) as WorktreeMutation;
      expect(decoded.expectedTargetToken, request.expectedTargetToken);
      final outcome = await f.engine.mutate(f.repository, decoded);
      expect(outcome.error!.code, GitErrorCode.staleReview);
      expect(await File('$path/owned').readAsString(), 'replacement data');
      expect(await File('$path/a').readAsString(), 'parent bytes');
    },
  );

  test(
    'parent trust does not authorize execution in an initialized child repository',
    () async {
      final path = await addModule();
      final engine = GitEngine(
        runner: IsolatedGitRunner(f.home),
        authorize: (repo) => repo == f.repository,
      );
      final state = await engine.status(f.repository),
          content = await engine.content(
            f.repository,
            path,
            const ContentVersion.working(),
          );
      final outcome = await engine.mutate(
        f.repository,
        SubmoduleMutation(
          SubmoduleAction.synchronize,
          [path],
          expectedHead: state.head,
          expectedIndex: state.indexToken,
          contentTokens: {path.key: content.token},
        ),
      );
      expect(outcome.error!.code, GitErrorCode.trustRequired);
      expect(await f.git(['rev-parse', ':nested']), content.oid!.value);
    },
  );
}
