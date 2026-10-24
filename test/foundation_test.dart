import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:busystack_git/busystack_git.dart';
import 'package:busystack_git/src/parsers.dart';
import 'package:test/test.dart';
import 'support/isolated_runner.dart';

void main() {
  late Directory fixture, repo, isolatedHome;
  late GitEngine engine;
  Future<ProcessResult> git(
    List<String> args, {
    String? cwd,
    bool check = true,
  }) async {
    final result = await Process.run(
      '/usr/bin/git',
      args,
      workingDirectory: cwd ?? repo.path,
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
      environment: {
        'HOME': isolatedHome.path,
        'XDG_CONFIG_HOME': isolatedHome.path,
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_AUTHOR_NAME': 'Fixture',
        'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
        'GIT_COMMITTER_NAME': 'Fixture',
        'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
      },
    );
    if (check && result.exitCode != 0) fail('${args.first}: ${result.stderr}');
    return result;
  }

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('bsg-test-');
    repo = await Directory('${fixture.path}/repo').create();
    isolatedHome = await Directory('${fixture.path}/home').create();
    await IsolatedGitRunner.prepare(isolatedHome.path);
    await git(['init', '--initial-branch=main']);
    await git(['config', 'user.name', 'Fixture']);
    await git(['config', 'user.email', 'fixture@example.invalid']);
    engine = GitEngine(
      runner: IsolatedGitRunner(isolatedHome.path),
      authorize: (_) => true,
    );
  });
  tearDown(() async {
    await fixture.delete(recursive: true);
  });
  test(
    'root/subfolder, unborn, linked worktree, detached and bare discovery',
    () async {
      final identity = (await engine.discover(repo.path))!;
      expect((await engine.status(identity)).branch, 'main');
      expect((await engine.status(identity)).head, isNull);
      await Directory('${repo.path}/sub').create();
      expect(await engine.discover('${repo.path}/sub'), identity);
      await File('${repo.path}/a.md').writeAsString('a\n');
      await git(['add', '.']);
      await git(['commit', '-m', 'base']);
      await git(['worktree', 'add', '-b', 'linked', '${fixture.path}/linked']);
      final linked = (await engine.discover('${fixture.path}/linked'))!;
      expect(linked.commonDir, identity.commonDir);
      expect(linked.gitDir, isNot(identity.gitDir));
      await git(['checkout', '--detach']);
      expect((await engine.status(identity)).branch, isNull);
      await git(['init', '--bare', '${fixture.path}/bare']);
      expect((await engine.discover('${fixture.path}/bare'))!.bare, isTrue);
      expect(await engine.discover(isolatedHome.path), isNull);
    },
  );
  test(
    'paths preserve byte identity and stage literal metacharacters',
    () async {
      final names = ['a b', 'café', 'tab\tline\n', '-dash', ':(glob)*', 'x[1]'];
      for (final name in names) {
        await File('${repo.path}/$name').writeAsString(name);
      }
      final raw = Uint8List.fromList([
        ...utf8.encode('${repo.path}/'),
        0xff,
        0x61,
      ]);
      await File.fromRawPath(raw).writeAsBytes([1, 2, 3]);
      final identity = (await engine.discover(repo.path))!,
          snapshot = await engine.status((await engine.discover(repo.path))!);
      expect(snapshot.changes.length, 7);
      final odd = snapshot.changes.singleWhere((e) => e.path.utf8Path == null);
      expect(odd.path.bytes, [0xff, 0x61]);
      final content = await engine.content(
        identity,
        odd.path,
        const ContentVersion.working(),
      );
      expect(content.bytes, [1, 2, 3]);
      final outcome = await engine.mutate(
        identity,
        StagePaths(
          [odd.path, RepoPath.text(':(glob)*')],
          expectedHead: snapshot.head,
          expectedIndex: snapshot.indexToken,
        ),
      );
      expect(outcome.completed, isTrue, reason: '${outcome.error}');
      expect(outcome.snapshot!.changes.where((e) => e.staged).length, 2);
      expect((await git(['ls-files', '-z'])).stdout, contains(':(glob)*'));
    },
  );
  test(
    'staging, partial index write and commit preserve unrelated edits',
    () async {
      final file = File('${repo.path}/a.md');
      await file.writeAsString('one\ntwo\nthree');
      await git(['add', '.']);
      await git(['commit', '-m', 'base']);
      await file.writeAsString('ONE\ntwo\nTHREE');
      await File('${repo.path}/b.md').writeAsString('staged\n');
      await git(['add', 'b.md']);
      final identity = (await engine.discover(repo.path))!,
          path = RepoPath.text('a.md');
      final snapshot = await engine.status(identity);
      final index = await engine.content(
        identity,
        path,
        const ContentVersion.index(),
      );
      final working = await engine.content(
        identity,
        path,
        const ContentVersion.working(),
      );
      final diff = computeTextDiff(index.text!, working.text!);
      final chosen = diff.changedIndices.take(2).toSet();
      final result = await engine.mutate(
        identity,
        WriteIndex(
          path,
          diff.select(chosen),
          expectedHead: snapshot.head,
          expectedIndex: snapshot.indexToken,
          expectedContent: index.token,
          expectedWorktree: working.token,
        ),
      );
      expect(result.completed, isTrue, reason: '${result.error}');
      expect(await file.readAsString(), 'ONE\ntwo\nTHREE');
      expect((await git(['show', ':a.md'])).stdout, 'ONE\ntwo\nthree');
      expect((await git(['show', ':b.md'])).stdout, 'staged\n');
      expect(
        result.snapshot!.changes.singleWhere((e) => e.path == path).staged,
        isTrue,
      );
      expect(
        result.snapshot!.changes.singleWhere((e) => e.path == path).unstaged,
        isTrue,
      );
      final commit = await engine.mutate(
        identity,
        CommitIndex(
          'partial',
          expectedHead: result.snapshot!.head,
          expectedIndex: result.snapshot!.indexToken,
        ),
      );
      expect(commit.createdCommit, isNotNull, reason: '${commit.error}');
      expect(commit.completed, isTrue);
      expect((await git(['show', 'HEAD:a.md'])).stdout, 'ONE\ntwo\nthree');
      final history = await engine.history(identity);
      expect(history.commits.length, 2);
      expect(history.commits.first.parents.single, snapshot.head);
    },
  );
  test(
    'index lock and stale review refuse without deleting another lock',
    () async {
      await File('${repo.path}/a').writeAsString('a');
      final id = (await engine.discover(repo.path))!,
          before = await engine.status((await engine.discover(repo.path))!);
      final lock = File('${id.gitDir}/index.lock');
      await lock.writeAsString('owned by terminal');
      final locked = await engine.mutate(
        id,
        StagePaths(
          [RepoPath.text('a')],
          expectedHead: before.head,
          expectedIndex: before.indexToken,
        ),
      );
      expect(locked.error!.code, GitErrorCode.locked);
      expect(await lock.readAsString(), 'owned by terminal');
      await lock.delete();
      await git(['add', 'a']);
      final stale = await engine.mutate(
        id,
        StagePaths(
          [RepoPath.text('a')],
          expectedHead: before.head,
          expectedIndex: before.indexToken,
        ),
      );
      expect(stale.error!.code, GitErrorCode.staleReview);
    },
  );
  test(
    'passive inspection disables fsmonitor and refuses configured filters without trust',
    () async {
      final marker = '${fixture.path}/ran';
      await git(['config', 'core.fsmonitor', 'touch $marker']);
      final safe = GitEngine(runner: IsolatedGitRunner(isolatedHome.path));
      final id = (await safe.discover(repo.path))!;
      await safe.status(id);
      expect(await File(marker).exists(), isFalse);
      await git(['config', 'filter.attack.clean', 'touch $marker']);
      await expectLater(
        safe.status(id),
        throwsA(
          isA<GitException>().having(
            (e) => e.code,
            'code',
            GitErrorCode.trustRequired,
          ),
        ),
      );
      expect(await File(marker).exists(), isFalse);
    },
  );
  test('byte status parser keeps rename source and conflict stages', () {
    final oid = 'a' * 40;
    final data = utf8.encode(
      '2 RM N... 100644 100644 100644 $oid $oid R100 new\tname\u0000old\nname\u0000'
      'u UU N... 100644 100644 100644 100644 $oid $oid $oid conflict\u0000',
    );
    final parsed = parseStatusV2(data);
    expect(parsed.changes.first.originalPath!.utf8Path, 'old\nname');
    expect(parsed.changes.last.conflictStages.keys, [1, 2, 3]);
  });
  test(
    'line selections round-trip additions deletions replacements CRLF and final newline',
    () {
      for (final pair in [
        ('a\n', 'a\nb\n'),
        ('a\nb\n', 'a\n'),
        ('a\nb', 'A\nB'),
        ('a\r\nb\r\n', 'a\r\nB\r\n'),
        ('', 'new'),
        ('old', ''),
        ('same', 'same'),
      ]) {
        final diff = computeTextDiff(pair.$1, pair.$2),
            all = diff.changedIndices.toSet();
        expect(utf8.decode(diff.select({})), pair.$1);
        expect(utf8.decode(diff.select(all)), pair.$2);
        expect(utf8.decode(diff.select(all, exclude: true)), pair.$1);
      }
    },
  );
  test(
    'sanitized diagnostics do not expose URL passwords and are length safe',
    () {
      expect(
        sanitizeGitDiagnostic('https://alice:secret@example.invalid/repo'),
        isNot(contains('secret')),
      );
      expect(
        sanitizeGitDiagnostic('Authorization: Bearer password'),
        isNot(contains('password')),
      );
    },
  );
}
