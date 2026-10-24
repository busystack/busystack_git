import 'dart:convert';
import 'dart:io';
import 'package:busystack_git/busystack_git.dart';
import 'package:test/test.dart';
import 'support/repository_fixture.dart';

void main() {
  late RepositoryFixture f;
  setUp(() async => f = await RepositoryFixture.create());
  tearDown(() async => f.close());
  test(
    'recorded and remote submodule updates remain separate from parent staging and commits',
    () async {
      final source = await Directory(
        '${f.directory.path}/module-source',
      ).create();
      await f.git(['init', '-b', 'main'], cwd: source.path);
      await File('${source.path}/module').writeAsString('recorded');
      await f.git(['add', '.'], cwd: source.path);
      await f.git(['commit', '-m', 'recorded'], cwd: source.path);
      final recorded = await f.git(['rev-parse', 'HEAD'], cwd: source.path);
      await f.git([
        '-c',
        'protocol.file.allow=always',
        'submodule',
        'add',
        source.path,
        'nested/module',
      ]);
      await f.git(['commit', '-m', 'add module']);
      final parentHead = await f.git(['rev-parse', 'HEAD']),
          child = '${f.root.path}/nested/module';
      await f.git(['config', 'protocol.file.allow', 'always'], cwd: child);
      await File('${source.path}/module').writeAsString('remote');
      await f.git(['add', '.'], cwd: source.path);
      await f.git(['commit', '-m', 'remote'], cwd: source.path);
      final remote = await f.git(['rev-parse', 'HEAD'], cwd: source.path),
          path = RepoPath.text('nested/module');
      Future<Json> inspect() async =>
          ((await f.engine.inspect(
                        f.repository,
                        const GitInspection(GitInspectionKind.submodules),
                      ))['entries']
                      as List)
                  .single
              as Json;
      expect((await inspect())['recorded'], recorded);
      expect((await inspect())['checkedOut'], recorded);
      var outcome = await f.mutate(
        (s) => SubmoduleMutation(
          SubmoduleAction.updateRemote,
          [path],
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(outcome.completed, isTrue, reason: '${outcome.error}');
      expect((await inspect())['recorded'], recorded);
      expect((await inspect())['checkedOut'], remote);
      expect(await f.git(['rev-parse', 'HEAD']), parentHead);
      outcome = await f.mutate(
        (s) => SubmoduleMutation(
          SubmoduleAction.updateRecorded,
          [path],
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(outcome.completed, isTrue, reason: '${outcome.error}');
      expect(await f.git(['rev-parse', 'HEAD'], cwd: child), recorded);
      await f.git(['checkout', remote], cwd: child);
      await File('${f.root.path}/parent-only').writeAsString('leave unstaged');
      outcome = await f.mutate(
        (s) => SubmoduleMutation(
          SubmoduleAction.stagePointer,
          [path],
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(outcome.completed, isTrue, reason: '${outcome.error}');
      expect(await f.git(['rev-parse', ':nested/module']), remote);
      expect(
        (await f.engine.status(
          f.repository,
        )).changes.singleWhere((c) => c.path == path).staged,
        isTrue,
      );
      expect(await f.git(['rev-parse', 'HEAD']), parentHead);
      expect(
        await File('${f.root.path}/parent-only').readAsString(),
        'leave unstaged',
      );
    },
  );
  test(
    'keep-index and staged-only stashes have distinct real index, worktree and stored contents',
    () async {
      await f.commit('a', utf8.encode('base-a'), 'base-a');
      await f.commit('b', utf8.encode('base-b'), 'base-b');
      final head = await f.git(['rev-parse', 'HEAD']);
      Future<void> edits() async {
        await File('${f.root.path}/a').writeAsString('staged-a');
        await f.git(['add', 'a']);
        await File('${f.root.path}/b').writeAsString('working-b');
        await File('${f.root.path}/untracked').writeAsString('untracked');
      }

      await edits();
      var outcome = await f.mutate(
        (s) => StashMutation(
          StashAction.create,
          message: 'keep staged',
          keepIndex: true,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(outcome.completed, isTrue, reason: '${outcome.error}');
      var oid = await f.git(['rev-parse', 'refs/stash']);
      expect(await f.git(['show', ':a']), 'staged-a');
      expect(await File('${f.root.path}/a').readAsString(), 'staged-a');
      expect(await File('${f.root.path}/b').readAsString(), 'base-b');
      expect(await f.git(['show', '$oid:b']), 'working-b');
      expect(
        await File('${f.root.path}/untracked').readAsString(),
        'untracked',
      );
      await f.git(['reset', '--hard', head]);
      await edits();
      outcome = await f.mutate(
        (s) => StashMutation(
          StashAction.create,
          message: 'only staged',
          stagedOnly: true,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(outcome.completed, isTrue, reason: '${outcome.error}');
      oid = await f.git(['rev-parse', 'refs/stash']);
      expect(await f.git(['show', ':a']), 'base-a');
      expect(await File('${f.root.path}/a').readAsString(), 'base-a');
      expect(await File('${f.root.path}/b').readAsString(), 'working-b');
      expect(await f.git(['show', '$oid:b']), 'base-b');
      expect(await f.git(['show', '$oid^2:a']), 'staged-a');
      expect(await f.git(['rev-parse', 'HEAD']), head);
    },
  );
  test(
    'reset modes preserve their documented scopes and reject worktree changes after hard-reset review',
    () async {
      final base = await f.commit('a', utf8.encode('base'), 'base');
      await f.commit('a', utf8.encode('tip'), 'tip');
      await File('${f.root.path}/a').writeAsString('working');
      var outcome = await f.mutate(
        (s) => ResetBranch(
          base,
          ResetMode.soft,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(outcome.completed, isTrue, reason: '${outcome.error}');
      expect(await f.git(['show', ':a']), 'tip');
      expect(await File('${f.root.path}/a').readAsString(), 'working');
      outcome = await f.mutate(
        (s) => ResetBranch(
          base,
          ResetMode.mixed,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(outcome.completed, isTrue, reason: '${outcome.error}');
      expect(await f.git(['show', ':a']), 'base');
      final reviewed = await f.engine.status(f.repository);
      await File('${f.root.path}/a').writeAsString('external change');
      expect(
        (await f.engine.status(f.repository)).token,
        isNot(reviewed.token),
      );
      outcome = await f.engine.mutate(
        f.repository,
        ResetBranch(
          base,
          ResetMode.hard,
          expectedHead: reviewed.head,
          expectedIndex: reviewed.indexToken,
          expectedWorkingToken: reviewed.token,
        ),
      );
      expect(outcome.error!.code, GitErrorCode.staleReview);
      expect(await File('${f.root.path}/a').readAsString(), 'external change');
      outcome = await f.mutate(
        (s) => ResetBranch(
          base,
          ResetMode.hard,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
          expectedWorkingToken: s.token,
        ),
      );
      expect(outcome.completed, isTrue, reason: '${outcome.error}');
      expect(await File('${f.root.path}/a').readAsString(), 'base');
    },
  );
  test(
    'selective stashing treats pathspec magic and untracked filenames literally',
    () async {
      const literal = ':(glob)*';
      await f.commit(literal, utf8.encode('base'), 'literal filename');
      await f.commit('ordinary', utf8.encode('ordinary base'), 'ordinary');
      await File('${f.root.path}/$literal').writeAsString('literal change');
      await File('${f.root.path}/ordinary').writeAsString('unrelated change');
      await File('${f.root.path}/-new\nfile').writeAsString('untracked bytes');
      final result = await f.mutate(
        (s) => StashMutation(
          StashAction.create,
          message: 'selected literal paths',
          paths: [RepoPath.text(literal), RepoPath.text('-new\nfile')],
          includeUntracked: true,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(result.completed, isTrue, reason: '${result.error}');
      expect(await File('${f.root.path}/$literal').readAsString(), 'base');
      expect(
        await File('${f.root.path}/ordinary').readAsString(),
        'unrelated change',
      );
      expect(await File('${f.root.path}/-new\nfile').exists(), isFalse);
      final stash = GitOid(await f.git(['rev-parse', 'refs/stash']));
      final applied = await f.mutate(
        (s) => StashMutation(
          StashAction.apply,
          identity: stash,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(applied.completed, isTrue, reason: '${applied.error}');
      expect(
        await File('${f.root.path}/$literal').readAsString(),
        'literal change',
      );
      expect(
        await File('${f.root.path}/-new\nfile').readAsString(),
        'untracked bytes',
      );
      expect(
        await File('${f.root.path}/ordinary').readAsString(),
        'unrelated change',
      );
      expect(await f.git(['rev-parse', 'refs/stash']), stash.value);
    },
  );
  test(
    'split-index updates preserve unrelated entries, executable modes and shared index permissions',
    () async {
      await f.commit('a', utf8.encode('base'), 'base');
      await f.commit('other', utf8.encode('other'), 'other');
      await f.git(['update-index', '--split-index']);
      await File('${f.root.path}/other').writeAsString('staged elsewhere');
      await f.git(['add', 'other']);
      await File('${f.root.path}/a').writeAsString('working');
      await f.git(['update-index', '--chmod=+x', 'a']);
      await Process.run('chmod', ['0660', '${f.repository.gitDir}/index']);
      final expectedMode =
          (await File('${f.repository.gitDir}/index').stat()).mode & 0x1ff;
      final path = RepoPath.text('a'),
          index = await f.engine.content(
            f.repository,
            RepoPath.text('a'),
            const ContentVersion.index(),
          );
      final working = await f.engine.content(
        f.repository,
        path,
        const ContentVersion.working(),
      );
      final other = await f.git(['rev-parse', ':other']);
      final outcome = await f.mutate(
        (s) => WriteIndex(
          path,
          utf8.encode('selected'),
          mode: '100755',
          expectedHead: s.head,
          expectedIndex: s.indexToken,
          expectedContent: index.token,
          expectedWorktree: working.token,
        ),
      );
      expect(outcome.completed, isTrue, reason: '${outcome.error}');
      expect(await f.git(['show', ':a']), 'selected');
      expect(await f.git(['rev-parse', ':other']), other);
      expect(await File('${f.root.path}/a').readAsString(), 'working');
      expect(
        (await f.git(['ls-files', '--stage', 'a'])).startsWith('100755'),
        isTrue,
      );
      expect(
        (await File('${f.repository.gitDir}/index').stat()).mode & 0x1ff,
        expectedMode,
      );
    },
  );
}
