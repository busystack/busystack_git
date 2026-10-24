import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:busystack_git/busystack_git.dart';
import 'package:test/test.dart';
import 'support/repository_fixture.dart';

void main() {
  late RepositoryFixture f;
  setUp(() async => f = await RepositoryFixture.create());
  tearDown(() async => f.close());
  Future<GitOid> commit(String path, String text, String message) =>
      f.commit(path, utf8.encode(text), message);

  test(
    'history rejects a repository handle after metadata replacement',
    () async {
      await commit('a', 'original', 'original');
      await f.engine.history(f.repository);
      final saved = await Directory(
        f.repository.gitDir,
      ).rename('${f.directory.path}/saved-git');
      await f.git(['init', '-b', 'replacement']);
      await f.commit('a', utf8.encode('replacement'), 'replacement');
      await expectLater(
        f.engine.history(f.repository),
        throwsA(
          isA<GitException>().having(
            (e) => e.code,
            'category',
            GitErrorCode.staleReview,
          ),
        ),
      );
      expect(await saved.exists(), isTrue);
      expect(await f.git(['log', '-1', '--format=%s']), 'replacement');
    },
  );

  test(
    'read-only metadata permits status/history and rejects a mutation without creating locks',
    () async {
      final head = await commit('a', 'base', 'base');
      await File('${f.root.path}/a').writeAsString('working');
      await Process.run('chmod', ['0555', f.repository.gitDir]);
      try {
        final state = await f.engine.status(f.repository);
        expect(state.head, head);
        expect(state.capabilities.writeMetadata, isFalse);
        expect(state.changes.single.unstaged, isTrue);
        expect((await f.engine.history(f.repository)).commits.single.oid, head);
        await expectLater(
          f.engine.mutate(
            f.repository,
            StagePaths(
              [RepoPath.text('a')],
              expectedHead: state.head,
              expectedIndex: state.indexToken,
            ),
          ),
          throwsA(
            isA<GitException>().having(
              (e) => e.code,
              'category',
              GitErrorCode.readOnly,
            ),
          ),
        );
        expect(
          await File('${f.repository.gitDir}/index.lock').exists(),
          isFalse,
        );
        expect(await File('${f.root.path}/a').readAsString(), 'working');
      } finally {
        await Process.run('chmod', ['0755', f.repository.gitDir]);
      }
    },
  );
  test(
    'a whole-file status selection becomes stale when working bytes change without changing index status',
    () async {
      await commit('a', 'base', 'base');
      await File('${f.root.path}/a').writeAsString('reviewed');
      final reviewed = await f.engine.status(f.repository),
          index = await f.git(['rev-parse', ':a']);
      await File('${f.root.path}/a').writeAsString('external newer edit');
      final result = await f.engine.mutate(
        f.repository,
        StagePaths(
          [RepoPath.text('a')],
          expectedHead: reviewed.head,
          expectedIndex: reviewed.indexToken,
          expectedSnapshot: reviewed.token,
        ),
      );
      expect(result.error!.code, GitErrorCode.staleReview);
      expect(await f.git(['rev-parse', ':a']), index);
      expect(
        await File('${f.root.path}/a').readAsString(),
        'external newer edit',
      );
    },
  );

  test(
    'unborn, bare, detached, gitfile, nested, subfolder and SHA-256 identities stay distinct',
    () async {
      final unborn = await f.engine.status(f.repository);
      expect(unborn.head, isNull);
      expect(unborn.branch, 'main');
      final first = await commit('folder/file', 'one', 'one');
      expect(
        (await f.engine.discover('${f.root.path}/folder'))!.key,
        f.repository.key,
      );
      await f.git([
        'worktree',
        'add',
        '-b',
        'linked',
        '${f.directory.path}/linked',
      ]);
      final linked = (await f.engine.discover('${f.directory.path}/linked'))!;
      expect(linked.commonDir, f.repository.commonDir);
      expect(linked.gitDir, isNot(f.repository.gitDir));
      expect(linked.key, isNot(f.repository.key));
      expect(await File('${linked.root}/.git').exists(), isTrue);
      await f.git(['init', '-b', 'nested', '${f.root.path}/nested']);
      final nested = (await f.engine.discover('${f.root.path}/nested'))!;
      expect(nested.commonDir, isNot(f.repository.commonDir));
      await f.git(['switch', '--detach', first.value]);
      expect((await f.engine.status(f.repository)).branch, isNull);
      await f.git(['clone', '--bare', f.root.path, '${f.directory.path}/bare']);
      final bare = (await f.engine.discover('${f.directory.path}/bare'))!;
      expect(bare.bare, isTrue);
      expect((await f.engine.history(bare)).commits.single.oid, first);
      final sha = await RepositoryFixture.create(objectFormat: 'sha256');
      try {
        final oid = await sha.commit('a', [0, 1, 2], 'sha256');
        expect(sha.repository.objectFormat, 'sha256');
        expect(oid.value.length, 64);
        expect(
          (await sha.engine.history(sha.repository)).commits.single.oid,
          oid,
        );
      } finally {
        await sha.close();
      }
    },
  );

  test(
    'byte-sensitive filenames retain exact identity through history, blame, diff and restore',
    () async {
      final path = RepoPath([255, ...utf8.encode(' prose\t\n.md')]);
      final file = File.fromRawPath(
        Uint8List.fromList([...utf8.encode('${f.root.path}/'), ...path.bytes]),
      );
      await file.writeAsString('first\nsecond\n');
      var result = await f.mutate(
        (s) => StagePaths(
          [path],
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(result.completed, isTrue, reason: '${result.error}');
      result = await f.mutate(
        (s) => CommitIndex(
          'byte path',
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(result.completed, isTrue, reason: '${result.error}');
      final oid = result.snapshot!.head!;
      final page = await f.engine.history(
        f.repository,
        filter: HistoryFilter(path: path, follow: true),
      );
      expect(page.commits.single.oid, oid);
      final followed = await f.engine.inspect(
        f.repository,
        GitInspection(GitInspectionKind.fileHistory, path: path),
      );
      expect(
        RepoPath.fromJson(
          ((followed['entries'] as List).single as Json)['pathAtCommit'],
        ),
        path,
      );
      final blamed = await f.engine.inspect(
        f.repository,
        GitInspection(
          GitInspectionKind.blame,
          path: path,
          revision: oid,
          limit: 2,
        ),
      );
      expect(
        (blamed['lines'] as List).map(
          (e) => RepoPath.fromJson((e as Json)['path']),
        ),
        everyElement(path),
      );
      await file.writeAsString('FIRST\nsecond\n');
      final patch = await f.engine.patch(
        f.repository,
        GitDiffSpec(
          const ContentVersion.index(),
          const ContentVersion.working(),
          paths: [path],
        ),
      );
      expect(utf8.decode(patch.bytes), contains('+FIRST'));
      final source = await f.engine.content(
        f.repository,
        path,
        const ContentVersion.working(),
      );
      result = await f.mutate(
        (s) => RestorePaths(
          [path],
          expectedHead: s.head,
          expectedIndex: s.indexToken,
          contentTokens: {path.key: source.token},
        ),
      );
      expect(result.completed, isTrue, reason: '${result.error}');
      expect(await file.readAsString(), 'first\nsecond\n');
    },
  );

  test(
    'shallow parent boundaries remain real parents and never become an empty file',
    () async {
      await commit('a', 'one', 'one');
      final tip = await commit('a', 'two', 'two');
      final path = '${f.directory.path}/shallow';
      await f.git(['clone', '--depth=1', 'file://${f.root.path}', path]);
      final repo = (await f.engine.discover(path))!;
      expect(repo.shallow, isTrue);
      final history = await f.engine.history(repo);
      expect(history.commits.single.oid, tip);
      expect(history.commits.single.parents, hasLength(1));
      expect(history.commits.single.boundary, isTrue);
      await expectLater(
        f.engine.changedFiles(
          repo,
          tip,
          parent: history.commits.single.parents.single,
        ),
        throwsA(
          isA<GitException>().having(
            (e) => e.code,
            'category',
            GitErrorCode.missingContent,
          ),
        ),
      );
      await expectLater(
        f.engine.changedFiles(repo, tip),
        throwsA(
          isA<GitException>().having(
            (e) => e.code,
            'category',
            GitErrorCode.missingContent,
          ),
        ),
      );
    },
  );

  test(
    'rename-following history, blame and snapshot reads retain historical paths without checkout',
    () async {
      final old = await commit('old\tname', 'first\nsecond\n', 'initial');
      await f.git(['mv', 'old\tname', 'new name']);
      await f.git(['commit', '-m', 'rename']);
      await commit('new name', 'FIRST\nsecond\n', 'modify');
      final head = (await f.engine.status(f.repository)).head;
      final history = await f.engine.inspect(
        f.repository,
        GitInspection(
          GitInspectionKind.fileHistory,
          path: RepoPath.text('new name'),
        ),
      );
      final entries = (history['entries'] as List).cast<Json>();
      expect(entries.map((e) => e['status']), contains('R100'));
      expect(
        RepoPath.fromJson(entries.last['pathAtCommit']).utf8Path,
        'old\tname',
      );
      final blame = await f.engine.inspect(
        f.repository,
        GitInspection(
          GitInspectionKind.blame,
          path: RepoPath.text('new name'),
          revision: head,
          limit: 2,
        ),
      );
      final lines = (blame['lines'] as List).cast<Json>();
      expect(lines, hasLength(2));
      expect(lines.last['revision'], old.value);
      expect(RepoPath.fromJson(lines.last['path']).utf8Path, 'old\tname');
      final snapshot = await f.engine.content(
        f.repository,
        RepoPath.text('old\tname'),
        ContentVersion(ContentKind.commit, revision: old),
      );
      expect(snapshot.text, 'first\nsecond\n');
      expect((await f.engine.status(f.repository)).head, head);
      expect(await File('${f.root.path}/old\tname').exists(), isFalse);
    },
  );

  for (final values in <(String, String)>[
    ('a\nb\n', 'A\nb\n'),
    ('', 'new\n'),
    ('gone\n', ''),
    ('a\nb\nc\n', 'a\nB\nC\n'),
    ('a\r\nb\r\n', 'A\r\nb\r\n'),
    ('a\nb', 'a\nB'),
  ]) {
    test(
      'exact selected-line index transaction preserves working bytes ${jsonEncode([values.$1, values.$2])}',
      () async {
        final (before, after) = values;
        await commit('a', before, 'base');
        await commit('unrelated', 'base', 'other');
        await File('${f.root.path}/unrelated').writeAsString('staged');
        await f.git(['add', 'unrelated']);
        final unrelated = await f.git(['rev-parse', ':unrelated']);
        await File('${f.root.path}/a').writeAsString(after);
        final index = await f.engine.content(
          f.repository,
          RepoPath.text('a'),
          const ContentVersion.index(),
        );
        final working = await f.engine.content(
          f.repository,
          RepoPath.text('a'),
          const ContentVersion.working(),
        );
        final diff = computeTextDiff(before, after),
            selection = {diff.changedIndices.first};
        final outcome = await f.mutate(
          (s) => WriteIndex(
            RepoPath.text('a'),
            diff.select(selection),
            expectedHead: s.head,
            expectedIndex: s.indexToken,
            expectedContent: index.token,
            expectedWorktree: working.token,
          ),
        );
        expect(outcome.completed, isTrue, reason: '${outcome.error}');
        expect(
          (await f.engine.content(
            f.repository,
            RepoPath.text('a'),
            const ContentVersion.index(),
          )).bytes,
          diff.select(selection),
        );
        expect(
          await File('${f.root.path}/a').readAsBytes(),
          utf8.encode(after),
        );
        expect(await f.git(['rev-parse', ':unrelated']), unrelated);
        final stale = await f.mutate(
          (s) => WriteIndex(
            RepoPath.text('a'),
            Uint8List(0),
            expectedHead: s.head,
            expectedIndex: s.indexToken,
            expectedContent: index.token,
            expectedWorktree: 'stale',
          ),
        );
        expect(stale.error!.code, GitErrorCode.staleReview);
      },
    );
  }

  test(
    'large binary conflict chooses an exact stage without decoding or truncating',
    () async {
      final base = Uint8List(4 * 1024 * 1024 + 1024),
          incoming = Uint8List.fromList([...base]..[40] = 8),
          current = Uint8List.fromList([...base]..[40] = 9);
      await f.commit('binary', base, 'base');
      await f.git(['switch', '-c', 'topic']);
      final tip = await f.commit('binary', incoming, 'incoming');
      await f.git(['switch', 'main']);
      await f.commit('binary', current, 'current');
      final merge = await f.mutate(
        (s) => MergeRevision(
          tip,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(merge.phase, GitOperationPhase.stopped);
      final path = RepoPath.text('binary'),
          info = await f.engine.inspect(
            f.repository,
            GitInspection(
              GitInspectionKind.conflict,
              path: RepoPath.text('binary'),
            ),
          );
      final stages = info['stages'] as Json;
      final outcome = await f.mutate(
        (s) => ResolveConflict(
          path,
          ConflictChoice.right,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
          expectedWorking: (info['working'] as Json)['token'] as String,
          expectedStages: {
            for (final e in stages.entries)
              int.parse(e.key):
                  '${(e.value as Json)['mode']}:${(e.value as Json)['oid']}',
          },
        ),
      );
      expect(outcome.error, isNull);
      expect(outcome.snapshot!.operation.unmerged, isFalse);
      expect(await File('${f.root.path}/binary').readAsBytes(), incoming);
      expect(
        await f.git(['rev-parse', ':binary']),
        (stages['3'] as Json)['oid'],
      );
    },
  );

  test(
    'an open linked worktree cannot be moved or removed and releases its lease on close',
    () async {
      await commit('a', 'base', 'base');
      final path = '${f.directory.path}/linked';
      await f.git(['worktree', 'add', '-b', 'linked', path]);
      final linked = (await f.engine.discover(path))!;
      final subscription = f.engine.watch(linked).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      for (final action in [WorktreeAction.remove, WorktreeAction.move]) {
        final outcome = await f.mutate(
          (s) => WorktreeMutation(
            action,
            path,
            destination: '${f.directory.path}/moved',
            expectedHead: s.head,
            expectedIndex: s.indexToken,
          ),
        );
        expect(outcome.error!.code, GitErrorCode.locked);
        expect(await Directory(path).exists(), isTrue);
      }
      await subscription.cancel();
      final reviewed =
          ((await f.engine.inspect(
                    f.repository,
                    const GitInspection(GitInspectionKind.worktrees),
                  ))['entries']
                  as List)
              .cast<Json>()
              .singleWhere((entry) => entry['path'] == path);
      final removed = await f.mutate(
        (s) => WorktreeMutation(
          WorktreeAction.remove,
          path,
          expectedTargetToken: reviewed['reviewToken'] as String,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(removed.completed, isTrue, reason: '${removed.error}');
      expect(await Directory(path).exists(), isFalse);
    },
  );
}
