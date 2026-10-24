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

  test(
    'removed parent directories permit exact byte-path review, staging and historical restoration',
    () async {
      await f.commit('base', utf8.encode('base'), 'base');
      final path = RepoPath([...utf8.encode('missing/'), 255, 10]);
      File file(RepoPath path) => File.fromRawPath(
        Uint8List.fromList([...utf8.encode('${f.root.path}/'), ...path.bytes]),
      );
      final bytes = [0, 255, 13, 10, 97];
      await Directory('${f.root.path}/missing').create();
      await file(path).writeAsBytes(bytes);
      var outcome = await f.mutate(
        (s) => StagePaths(
          [path],
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(outcome.completed, isTrue, reason: '${outcome.error}');
      await f.git(['commit', '-m', 'byte-named blob']);
      final revision = GitOid(await f.git(['rev-parse', 'HEAD']));
      await Directory('${f.root.path}/missing').delete(recursive: true);
      final absent = await f.engine.content(
        f.repository,
        path,
        const ContentVersion.working(),
      );
      expect(absent.availability, ContentAvailability.absent);
      final status = await f.engine.status(f.repository);
      expect(status.changes.single.path, path);
      outcome = await f.engine.mutate(
        f.repository,
        StagePaths(
          [path],
          expectedHead: status.head,
          expectedIndex: status.indexToken,
          expectedSnapshot: status.token,
          contentTokens: {path.key: absent.token},
        ),
      );
      expect(outcome.completed, isTrue, reason: '${outcome.error}');
      outcome = await f.mutate(
        (s) => RestorePaths(
          [path],
          target: RestoreTarget.both,
          revision: revision,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
          contentTokens: {path.key: absent.token},
        ),
      );
      expect(outcome.completed, isTrue, reason: '${outcome.error}');
      expect(await file(path).readAsBytes(), bytes);
      final target = RepoPath([...utf8.encode('recovered/deep/'), 254]);
      final missing = await f.engine.content(
        f.repository,
        target,
        const ContentVersion.working(),
      );
      final index = (await f.engine.status(f.repository)).indexToken;
      outcome = await f.mutate(
        (s) => RestoreFileRevision(
          path,
          target,
          revision,
          expectedWorking: missing.token,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(outcome.completed, isTrue, reason: '${outcome.error}');
      expect(await file(target).readAsBytes(), bytes);
      expect((await f.engine.status(f.repository)).indexToken, index);
      expect(await f.git(['rev-parse', 'HEAD']), revision.value);
    },
  );

  test(
    'missing submodule parent can be inspected and explicitly initialized at its recorded commit',
    () async {
      final source = await Directory('${f.directory.path}/source').create();
      await f.git(['init', '-b', 'main'], cwd: source.path);
      await File('${source.path}/a').writeAsString('recorded child bytes');
      await f.git(['add', '.'], cwd: source.path);
      await f.git(['commit', '-m', 'child'], cwd: source.path);
      final recorded = await f.git(['rev-parse', 'HEAD'], cwd: source.path);
      await f.git([
        '-c',
        'protocol.file.allow=always',
        'submodule',
        'add',
        source.path,
        'nested/module',
      ]);
      await f.git(['commit', '-m', 'module']);
      await f.git(['config', 'protocol.file.allow', 'always']);
      await Directory('${f.root.path}/nested').delete(recursive: true);
      final inspection = await f.engine.inspect(
        f.repository,
        const GitInspection(GitInspectionKind.submodules),
      );
      final row = (inspection['entries'] as List).single as Json;
      expect(row['initialized'], isFalse);
      expect(row['checkedOut'], isNull);
      expect(row['recorded'], recorded);
      final path = RepoPath.fromJson(row['path']);
      final outcome = await f.engine.mutate(
        f.repository,
        SubmoduleMutation(
          SubmoduleAction.updateRecorded,
          [path],
          expectedHead: oidOrNull(inspection['head']),
          expectedIndex: inspection['indexToken'] as String,
          contentTokens: {path.key: row['workingToken'] as String},
        ),
      );
      expect(outcome.completed, isTrue, reason: '${outcome.error}');
      expect(
        await f.git(['rev-parse', 'HEAD'], cwd: '${f.root.path}/nested/module'),
        recorded,
      );
      expect(
        await File('${f.root.path}/nested/module/a').readAsString(),
        'recorded child bytes',
      );
    },
  );

  test(
    'restoration still refuses an existing symlink ancestor and leaves outside bytes untouched',
    () async {
      final revision = await f.commit('source', [0, 255, 10], 'source');
      final outside = await Directory('${f.directory.path}/outside').create();
      await File('${outside.path}/data').writeAsString('outside bytes');
      final target = RepoPath.text('restore/deep/data');
      final missing = await f.engine.content(
        f.repository,
        target,
        const ContentVersion.working(),
      );
      await Directory('${f.root.path}/restore').create();
      await Link('${f.root.path}/restore/deep').create(outside.path);
      final outcome = await f.mutate(
        (s) => RestoreFileRevision(
          RepoPath.text('source'),
          target,
          revision,
          expectedWorking: missing.token,
          expectedHead: s.head,
          expectedIndex: s.indexToken,
        ),
      );
      expect(outcome.error!.code, GitErrorCode.unsafePath);
      expect(
        await File('${outside.path}/data').readAsString(),
        'outside bytes',
      );
    },
  );
}
